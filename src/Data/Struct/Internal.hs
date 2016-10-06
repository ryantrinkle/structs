{-# LANGUAGE CPP #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE Unsafe #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DefaultSignatures #-}
{-# OPTIONS_HADDOCK not-home #-}
-----------------------------------------------------------------------------
-- |
-- Copyright   :  (C) 2015 Edward Kmett
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Edward Kmett <ekmett@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable
--
-----------------------------------------------------------------------------

module Data.Struct.Internal where

import Control.Exception
import Control.Monad.Primitive
import Control.Monad.ST
import Data.Primitive
import Data.Coerce
import GHC.Exts

#ifdef HLINT
{-# ANN module "HLint: ignore Eta reduce" #-}
{-# ANN module "HLint: ignore Unused LANGUAGE pragma" #-}
{-# ANN module "HLint: ignore Avoid lambda" #-}
{-# ANN module "HLint: ignore Redundant lambda" #-}
#endif

data NullPointerException = NullPointerException deriving (Show, Exception)

-- | A 'Dict' reifies an instance of the constraint @p@ into a value.
data Dict p where
  Dict :: p => Dict p

-- | Run an ST calculation inside of a PrimMonad. This lets us avoid dispatching everything through the 'PrimMonad' dictionary.
st :: PrimMonad m => ST (PrimState m) a -> m a
st = primToPrim
{-# INLINE[0] st #-}

-- | An instance for 'Struct' @t@ is a witness to the machine-level
--   equivalence of @t@ and @Object@.
class Struct t where
  struct :: Dict (Coercible (t s) (Object s))
#ifndef HLINT
  default struct :: Coercible (t s) (Object s) => Dict (Coercible (t s) (Object s))
#endif
  struct = Dict
  {-# MINIMAL #-}

data Object s = Object { runObject :: SmallMutableArray# s Any }

instance Struct Object

coerceF :: Dict (Coercible a b) -> a -> b
coerceF Dict = coerce
{-# INLINE coerceF #-}

coerceB :: Dict (Coercible a b) -> b -> a
coerceB Dict = coerce
{-# INLINE coerceB #-}

destruct :: Struct t => t s -> SmallMutableArray# s Any
destruct = \x -> runObject (coerceF struct x)
{-# INLINE destruct #-}

construct :: Struct t => SmallMutableArray# s Any -> t s
construct = \x -> coerceB struct (Object x)
{-# INLINE construct #-}

unsafeCoerceStruct :: (Struct x, Struct y) => x s -> y s
unsafeCoerceStruct x = construct (destruct x)

eqStruct :: Struct t => t s -> t s -> Bool
eqStruct = \x y -> isTrue# (destruct x `sameSmallMutableArray#` destruct y)
{-# INLINE eqStruct #-}

instance Eq (Object s) where
  (==) = eqStruct

#ifndef HLINT
#if __GLASGOW_HASKELL__ >= 800
pattern Struct :: Struct t => () => SmallMutableArray# s Any -> t s
#else
pattern Struct :: () => Struct t => SmallMutableArray# s Any -> t s
#endif
pattern Struct x <- (destruct -> x) where
  Struct x = construct x
#endif

-- | Allocate a structure made out of `n` slots. Initialize the structure before proceeding!
alloc :: (PrimMonad m, Struct t) => Int -> m (t (PrimState m))
alloc (I# n#) = primitive $ \s -> case newSmallArray# n# undefined s of (# s', b #) -> (# s', construct b #)

--------------------------------------------------------------------------------
-- * Tony Hoare's billion dollar mistake
--------------------------------------------------------------------------------

-- | Box is designed to mirror object's single field but using the 'Null' type
-- instead of a mutable array. This hack relies on GHC reusing the same 'Null'
-- data constructor for all occurrences. Box's field must not be strict to
-- prevent the compiler from making assumptions about its contents.
data Box = Box Null
data Null = Null

-- | Predicate to check if a struct is 'Nil'.
--
-- >>> isNil (Nil :: Object (PrimState IO))
-- True
-- >>> o <- alloc 1 :: IO (Object (PrimState IO))
-- >>> isNil o
-- False
isNil :: Struct t => t s -> Bool
isNil t = isTrue# (unsafeCoerce# reallyUnsafePtrEquality# (destruct t) Null)
{-# INLINE isNil #-}

#ifndef HLINT
-- | Truly imperative.
#if __GLASGOW_HASKELL__ >= 800
pattern Nil :: Struct t => () => t s
#else
pattern Nil :: () => Struct t => t s
#endif
pattern Nil <- (isNil -> True) where
  Nil = unsafeCoerce# Box Null
#endif

--------------------------------------------------------------------------------
-- * Faking SmallMutableArrayArray#s
--------------------------------------------------------------------------------

writeSmallMutableArraySmallArray# :: SmallMutableArray# s Any -> Int# -> SmallMutableArray# s Any -> State# s -> State# s
writeSmallMutableArraySmallArray# m i a s = unsafeCoerce# writeSmallArray# m i a s
{-# INLINE writeSmallMutableArraySmallArray# #-}

readSmallMutableArraySmallArray# :: SmallMutableArray# s Any -> Int# -> State# s -> (# State# s, SmallMutableArray# s Any #)
readSmallMutableArraySmallArray# m i s = unsafeCoerce# readSmallArray# m i s
{-# INLINE readSmallMutableArraySmallArray# #-}

writeMutableByteArraySmallArray# :: SmallMutableArray# s Any -> Int# -> MutableByteArray# s -> State# s -> State# s
writeMutableByteArraySmallArray# m i a s = unsafeCoerce# writeSmallArray# m i a s
{-# INLINE writeMutableByteArraySmallArray# #-}

readMutableByteArraySmallArray# :: SmallMutableArray# s Any -> Int# -> State# s -> (# State# s, MutableByteArray# s #)
readMutableByteArraySmallArray# m i s = unsafeCoerce# readSmallArray# m i s
{-# INLINE readMutableByteArraySmallArray# #-}

--------------------------------------------------------------------------------
-- * Field Accessors
--------------------------------------------------------------------------------

-- | A 'Slot' is a reference to another unboxed mutable object.
data Slot x y = Slot
  (forall s. SmallMutableArray# s Any -> State# s -> (# State# s, SmallMutableArray# s Any #))
  (forall s. SmallMutableArray# s Any -> SmallMutableArray# s Any -> State# s -> State# s)

-- | We can compose slots to get a nested slot or field accessor
class Precomposable t where
  ( # ) :: Slot x y -> t y z -> t x z

instance Precomposable Slot where
  Slot gxy _ # Slot gyz syz = Slot
    (\x s -> case gxy x s of (# s', y #) -> gyz y s')
    (\x z s -> case gxy x s of (# s', y #) -> syz y z s')

-- | The 'Slot' at the given position in a 'Struct'
slot :: Int {- ^ slot -} -> Slot s t
slot (I# i) = Slot
  (\m s -> readSmallMutableArraySmallArray# m i s)
  (\m a s -> writeSmallMutableArraySmallArray# m i a s)

-- | Get the value from a 'Slot'
get ::
  (PrimMonad m, Struct x, Struct y) =>
  Slot x y -> x (PrimState m) -> m (y (PrimState m))
get (Slot go _) = \x -> primitive $ \s -> case go (destruct x) s of
                                            (# s', y #) -> (# s', construct y #)
{-# INLINE get #-}

-- | Set the value of a 'Slot'
set :: (PrimMonad m, Struct x, Struct y) => Slot x y -> x (PrimState m) -> y (PrimState m) -> m ()
set (Slot _ go) = \x y -> primitive_ (go (destruct x) (destruct y))
{-# INLINE set #-}

-- | A 'Field' is a reference from a struct to a normal Haskell data type.
data Field x a = Field
  (forall s. SmallMutableArray# s Any -> State# s -> (# State# s, a #))
  (forall s. SmallMutableArray# s Any -> a -> State# s -> State# s)

instance Precomposable Field where
  Slot gxy _ # Field gyz syz = Field
    (\x s -> case gxy x s of (# s', y #) -> gyz y s')
    (\x z s -> case gxy x s of (# s', y #) -> syz y z s')

-- | Store the reference to the Haskell data type in a normal field
field :: Int {- ^ slot -} -> Field s a
field (I# i) = Field
  (\m s -> unsafeCoerce# readSmallArray# m i s)
  (\m a s -> unsafeCoerce# writeSmallArray# m i a s)
{-# INLINE field #-}

-- | Store the reference in the nth slot in the nth argument, treated as a MutableByteArray
unboxedField :: Prim a => Int {- ^ slot -} -> Int {- ^ argument -} -> Field s a
unboxedField (I# i) (I# j) = Field
  (\m s -> case readMutableByteArraySmallArray# m i s of
     (# s', mba #) -> readByteArray# mba j s')
  (\m a s -> case readMutableByteArraySmallArray# m i s of
     (# s', mba #) -> writeByteArray# mba j a s')
{-# INLINE unboxedField #-}

-- | Initialized the mutable array used by 'unboxedField'. Returns the array
-- after storing it in the struct to help with initialization.
initializeUnboxedField ::
  (PrimMonad m, Struct x) =>
  Int             {- ^ slot     -} ->
  Int             {- ^ elements -} ->
  Int             {- ^ element size -} ->
  x (PrimState m) {- ^ struct   -} ->
  m (MutableByteArray (PrimState m))
initializeUnboxedField (I# i) (I# n) (I# z) m =
  primitive $ \s ->
    case newByteArray# (n *# z) s of
      (# s1, mba #) ->
        (# writeMutableByteArraySmallArray# (destruct m) i mba s1, MutableByteArray mba #)
{-# INLINE initializeUnboxedField #-}

-- | Get the value of a field in a struct
getField :: (PrimMonad m, Struct x) => Field x a -> x (PrimState m) -> m a
getField (Field go _) = \x -> primitive (go (destruct x))
{-# INLINE getField #-}

-- | Set the value of a field in a struct
setField :: (PrimMonad m, Struct x) => Field x a -> x (PrimState m) -> a -> m ()
setField (Field _ go) = \x y -> primitive_ (go (destruct x) y)
{-# INLINE setField #-}


--------------------------------------------------------------------------------
-- * Modifiers
--------------------------------------------------------------------------------

modifyField :: (Struct x, PrimMonad m) => Field x a -> x (PrimState m) -> (a -> a) -> m ()
modifyField s = \o f -> st (setField s o . f =<< getField s o)
{-# INLINE modifyField #-}

modifyField' :: (Struct x, PrimMonad m) => Field x a -> x (PrimState m) -> (a -> a) -> m ()
modifyField' s = \o f -> st (setField s o =<< (\x -> return $! f x) =<< getField s o)
{-# INLINE modifyField' #-}
