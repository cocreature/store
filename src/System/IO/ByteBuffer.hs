{-@ LIQUID "--no-termination" @-}
{-@ LIQUID "--short-names"    @-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-|
Module: System.IO.ByteBuffer
Description: Provides an efficient buffering abstraction.

A 'ByteBuffer' is a simple buffer for bytes.  It supports two
operations: refilling with the contents of a 'ByteString', and
consuming a fixed number of bytes.

It is implemented as a pointer, together with counters that keep track
of the offset and the number of bytes in the buffer.  Note that the
counters are simple 'IORef's, so 'ByteBuffer's are not thread-safe!

A 'ByteBuffer' is constructed by 'new' with a given starting length,
and will grow (by repeatedly multiplying its size by 1.5) whenever it
is being fed a 'ByteString' that is too large.
-}

module System.IO.ByteBuffer
       ( ByteBuffer
         -- * Allocation and Deallocation
       , new, free, with
         -- * Query for number of available bytes
       , totalSize, isEmpty, availableBytes
         -- * Feeding new input
       , copyByteString
         -- * Consuming bytes from the buffer
       , consume, unsafeConsume
       ) where

import           Control.Applicative
import           Control.Exception.Lifted (bracket)
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Control (MonadBaseControl)
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Internal as BS
import           Data.IORef
import           Data.Maybe (fromMaybe)
import           Data.Word
import           Foreign.ForeignPtr
import qualified Foreign.Marshal.Alloc as Alloc
import           Foreign.Marshal.Utils (copyBytes, moveBytes)
import           GHC.Ptr
import           Prelude

-- | A buffer into which bytes can be written.
--
-- Invariants:
--
-- * @size >= containedBytes >= consumedBytes >= 0@
--
-- * The range from @ptr@ to @ptr `plusPtr` size@ will be allocated
--
-- * The range from @ptr@ to @ptr `plusPtr` containedBytes@ will
--   contain bytes previously copied to the buffer
--
-- * The buffer contains @containedBytes - consumedBytes@ bytes of
--   data that have been copied to it, but not yet read.  They are in
--   the range from @ptr `plusPtr` consumedBytes@ to @ptr `plusPtr`
--   containedBytes@.
--
-- The first two of these items are encoded in Liquid Haskell, and can
-- be statically checked.
{-@
data BBRef = BBRef
    { size :: {v: Int | v >= 0 }
    , contained :: { v: Int | v >= 0 && v <= size }
    , consumed :: { v: Int | v >= 0 && v <= contained }
    , ptr :: { v: Ptr Word8 | (plen v) = size }
    }
@-}

data BBRef = BBRef {
      size      :: {-# UNPACK #-} !Int
      -- ^ The amount of memory allocated.
    , contained :: {-# UNPACK #-} !Int
      -- ^ The number of bytes that the 'ByteBuffer' currently holds.
    , consumed  :: {-# UNPACK #-} !Int
      -- ^ The number of bytes that have already been consumed.
    , ptr       :: {-# UNPACK #-} !(Ptr Word8)
      -- ^ This points to the beginning of the memory allocated for
      -- the 'ByteBuffer'
    }

type ByteBuffer = IORef BBRef

totalSize :: MonadIO m => ByteBuffer -> m Int
totalSize bb = liftIO $ size <$> readIORef bb
{-# INLINE totalSize #-}

isEmpty :: MonadIO m => ByteBuffer -> m Bool
isEmpty bb = liftIO $ (==0) <$> availableBytes bb
{-# INLINE isEmpty #-}

-- | Number of available bytes in a 'ByteBuffer' (that is, bytes that
-- have been copied to, but not yet read from the 'ByteBuffer'.
{-@ availableBytes :: MonadIO m => ByteBuffer -> m {v: Int | v >= 0} @-}
availableBytes :: MonadIO m => ByteBuffer -> m Int
availableBytes bb = do
    BBRef{..} <- liftIO $ readIORef bb
    return $ contained - consumed
{-# INLINE availableBytes #-}

-- | Allocates a new ByteBuffer with a given buffer size filling from
-- the given FillBuffer.
--
-- Note that 'ByteBuffer's created with 'new' have to be deallocated
-- explicitly using 'free'.  For automatic deallocation, consider
-- using 'with' instead.
new :: MonadIO m
    => Maybe Int
    -- ^ Size of buffer to allocate.  If 'Nothing', use the default
    -- value of 4MB
    -> m ByteBuffer
    -- ^ The byte buffer.
new ml = liftIO $ do
    let l = max 0 . fromMaybe (4*1024*1024) $ ml
    newPtr <- Alloc.mallocBytes l
    newIORef BBRef { ptr = newPtr
                   , size = l
                   , contained = 0
                   , consumed = 0
                   }
{-# INLINE new #-}

-- | Free a byte buffer.
free :: MonadIO m => ByteBuffer -> m ()
free bb = liftIO $ readIORef bb >>= Alloc.free . ptr
{-# INLINE free #-}

-- | Perform some action with a bytebuffer, with automatic allocation
-- and deallocation.
with :: (MonadIO m, MonadBaseControl IO m)
     => Maybe Int
     -- ^ Initial length of the 'ByteBuffer'.  If 'Nothing', use the
     -- default value of 4MB.
     -> (ByteBuffer -> m a)
     -> m a
with l action =
  bracket
    (new l)
    free
    action
{-# INLINE with #-}

-- | Reset a 'BBRef', i.e. copy all the bytes that have not yet
-- been consumed to the front of the buffer.
{-@ resetBBRef :: b:BBRef -> IO {v:BBRef | consumed v == 0 && contained v == contained b - consumed b && size v == size b} @-}
resetBBRef :: BBRef -> IO BBRef
resetBBRef bbref = do
    let available = contained bbref - consumed bbref
    moveBytes (ptr bbref) (ptr bbref `plusPtr` consumed bbref) available
    return BBRef { size = size bbref
                 , contained = available
                 , consumed = 0
                 , ptr = ptr bbref
                 }
{-# INLINE resetBBRef #-}

-- | Make sure the buffer is at least @minSize@ bytes long.
--
-- In order to avoid having to enlarge the buffer too often, we
-- multiply its size by a factor of 1.5 until it is at least @minSize@
-- bytes long.
{-@ enlargeBBRef :: b:BBRef -> i:Nat -> IO {v:BBRef | size v >= i && contained v == contained b && consumed v == consumed b} @-}
enlargeBBRef :: BBRef -> Int -> IO BBRef
enlargeBBRef bbref minSize= do
        let getNewSize s | s >= minSize = s
            getNewSize s = getNewSize $ (ceiling . (*(1.5 :: Double)) . fromIntegral) (max 1 s)
            newSize = getNewSize (size bbref)
        -- possible optimisation: since reallocation might copy the
        -- bytes anyway, we could discard the consumed bytes,
        -- basically 'reset'ting the buffer on the fly.
        ptr' <- Alloc.reallocBytes (ptr bbref) newSize
        return BBRef { size = newSize
                     , contained = contained bbref
                     , consumed = consumed bbref
                     , ptr = ptr'
                     }
{-# INLINE enlargeBBRef #-}

-- | Copy the contents of a 'ByteString' to a 'ByteBuffer'.
--
-- If necessary, the 'ByteBuffer' is enlarged and/or already consumed
-- bytes are dropped.
copyByteString :: MonadIO m => ByteBuffer -> ByteString -> m ()
copyByteString bb bs = liftIO $ do
    let (bsFptr, bsOffset, bsSize) = BS.toForeignPtr bs
    bbref <- readIORef bb
    -- if the byteBuffer is too small, resize it.
    let available = contained bbref - consumed bbref -- bytes not yet consumed
    bbref' <- if size bbref < bsSize + available
                then enlargeBBRef bbref (bsSize + available)
                else return bbref
    -- if it is currently too full, reset it
    bbref'' <- if bsSize + contained bbref' > size bbref'
                 then resetBBRef bbref'
                 else return bbref'
    -- now we can safely copy.
    withForeignPtr bsFptr $ \ bsPtr ->
        copyBytes (ptr bbref'' `plusPtr` contained bbref'')
                  (bsPtr `plusPtr` bsOffset)
                  bsSize
    writeIORef bb BBRef {
        size = size bbref''
        , contained = contained bbref'' + bsSize
        , consumed = consumed bbref''
        , ptr = ptr bbref''}
{-# INLINE copyByteString #-}

-- | Try to get a pointer to @n@ bytes from the 'ByteBuffer'.
--
-- Note that the pointer should be used before any other actions are
-- performed on the 'ByteBuffer'. It points to some address within the
-- buffer, so operations such as enlarging the buffer or feeding it
-- new data will change the data the pointer points to.  This is why
-- this function is called unsafe.
{-@ unsafeConsume :: MonadIO m => ByteBuffer -> n:Nat -> m (Either Int ({v:Ptr Word8 | plen v >= n})) @-}
unsafeConsume :: MonadIO m
        => ByteBuffer
        -> Int
        -- ^ n
        -> m (Either Int (Ptr Word8))
        -- ^ Will be @Left missing@ when there are only @n-missing@
        -- bytes left in the 'ByteBuffer'.
unsafeConsume bb n = liftIO $ do
    bbref <- readIORef bb
    let available = contained bbref - consumed bbref
    if available < n
        then return $ Left (n - available)
        else do
             writeIORef bb bbref { consumed = consumed bbref + n }
             return $ Right (ptr bbref `plusPtr` consumed bbref)
{-# INLINE unsafeConsume #-}

-- | As `unsafeConsume`, but instead of returning a `Ptr` into the
-- contents of the `ByteBuffer`, it returns a `ByteString` containing
-- the next @n@ bytes in the buffer.  This involves allocating a new
-- 'ByteString' and copying the @n@ bytes to it.
{-@ consume :: MonadIO m => ByteBuffer -> Nat -> m (Either Int ByteString) @-}
consume :: MonadIO m
        => ByteBuffer
        -> Int
        -> m (Either Int ByteString)
consume bb n = do
    mPtr <- unsafeConsume bb n
    case mPtr of
        Right ptr -> do
            bs <- liftIO $ createBS ptr n
            return (Right bs)
        Left missing -> return (Left missing)
{-# INLINE consume #-}

{-@ createBS :: p:(Ptr Word8) -> {v:Nat | v <= plen p} -> IO ByteString @-}
createBS :: Ptr Word8 -> Int -> IO ByteString
createBS ptr n = do
  fp  <- mallocForeignPtrBytes n
  withForeignPtr fp (\p -> copyBytes p ptr n)
  return (BS.PS fp 0 n)
{-# INLINE createBS #-}

-- below are liquid haskell qualifiers, and specifications for external functions.

{-@ qualif FPLenPLen(v:Ptr a, fp:ForeignPtr a): fplen fp = plen v @-}

{-@ Foreign.Marshal.Alloc.mallocBytes :: l:Nat -> IO (PtrN a l) @-}
{-@ Foreign.Marshal.Alloc.reallocBytes :: Ptr a -> l:Nat -> IO (PtrN a l) @-}
{-@ assume mallocForeignPtrBytes :: n:Nat -> IO (ForeignPtrN a n) @-}
{-@ type ForeignPtrN a N = {v:ForeignPtr a | fplen v = N} @-}
{-@ Foreign.Marshal.Utils.copyBytes :: p:Ptr a -> q:Ptr a -> {v:Nat | v <= plen p && v <= plen q} -> IO ()@-}
{-@ Foreign.Marshal.Utils.moveBytes :: p:Ptr a -> q:Ptr a -> {v:Nat | v <= plen p && v <= plen q} -> IO ()@-}
{-@ Foreign.Ptr.plusPtr :: p:Ptr a -> n:Nat -> {v:Ptr b | plen v == (plen p) - n} @-}

-- writing down the specification for ByteString is not as straightforward as it seems at first: the constructor
--
-- PS (ForeignPtr Word8) Int Int
--
-- has actually four arguments after unboxing (the ForeignPtr is an
-- Addr# and ForeignPtrContents), so restriciting the length of the
-- ForeignPtr directly in the specification of the datatype does not
-- work.  Instead, I chose to write a specification for toForeignPtr.
-- It seems that the liquidhaskell parser has problems with variables
-- declared in a tuple, so I have to define the following measures to
-- get at the ForeignPtr, offset, and length.
--
-- This is a bit awkward, maybe there is an easier way.

get1 :: (a,b,c) -> a
get1 (x,_,_) = x
{-@ measure get1 @-}
get2 :: (a,b,c) -> b
get2 (_,x,_) = x
{-@ measure get2 @-}
get3 :: (a,b,c) -> c
get3 (_,_,x) = x
{-@ measure get3 @-}

{-@ Data.ByteString.Internal.toForeignPtr :: ByteString ->
  {v:(ForeignPtr Word8, Int, Int) | get2 v >= 0
                                 && get2 v <= (fplen (get1 v))
                                 && get3 v >= 0
                                 && ((get3 v) + (get2 v)) <= (fplen (get1 v))} @-}

