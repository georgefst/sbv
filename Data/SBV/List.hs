-----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.List
-- Copyright   :  (c) Joel Burget, Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
--
-- A collection of list utilities, useful when working with symbolic lists.
-- To the extent possible, the functions in this module follow those of "Data.List"
-- so importing qualified is the recommended workflow.
-----------------------------------------------------------------------------

{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Data.SBV.List (
        -- * Length, emptiness
          length, null
        -- * Deconstructing/Reconstructing
        , head, tail, singleton, listToListAt, elemAt, (.!!), implode, concat, (.++)
        -- * Containment
        , isInfixOf, isSuffixOf, isPrefixOf
        -- * Sublists
        , take, drop, subList, replace, indexOf, offsetIndexOf
        ) where

import Prelude hiding (head, tail, length, take, drop, concat, null)
import qualified Prelude as P

import Data.SBV.Core.Data hiding (StrOp(..))
import Data.SBV.Core.List
import Data.SBV.Core.Model

import Data.List (genericLength, genericIndex, genericDrop, genericTake)
import qualified Data.List as L (tails, isSuffixOf, isPrefixOf, isInfixOf)

-- For doctest use only
--
-- $setup
-- >>> import Data.SBV.Provers.Prover (prove, sat)
-- >>> import Data.SBV.Utils.Boolean  ((==>), (&&&), bnot, (<=>))
-- >>> :set -XOverloadedLists

-- | Length of a list.
--
-- >>> sat $ \s -> length s .== 2
-- Satisfiable. Model:
--   s0 = "\NUL\NUL" :: String
-- >>> sat $ \s -> length s .< 0
-- Unsatisfiable
-- >>> prove $ \s1 s2 -> length s1 + length s2 .== length (s1 .++ s2)
-- Q.E.D.
length :: SymWord a => SList a -> SInteger
length = lift1 SeqLen (Just (fromIntegral . P.length))

-- | @`null` s@ is True iff the string is empty
--
-- >>> prove $ \s -> null s <=> length s .== 0
-- Q.E.D.
-- >>> prove $ \s -> null s <=> s .== ""
-- Q.E.D.
null :: SymWord a => SList a -> SBool
null l
  | Just cs <- unliteral l
  = literal (P.null cs)
  | True
  = l .== literal []

-- | @`head`@ returns the first element of a list. Unspecified if the list is empty.
--
-- >>> prove $ \c -> head (singleton c) .== c
-- Q.E.D.
head :: SymWord a => SList a -> SBV a
head = (`elemAt` 0)

-- | @`tail`@ returns the tail of a list. Unspecified if the list is empty.
--
-- >>> prove $ \h t -> tail (singleton h .++ t) .== t
-- Q.E.D.
-- >>> prove $ \l -> length l .> 0 ==> length (tail l) .== length l - 1
-- Q.E.D.
-- >>> prove $ \l -> bnot (null l) ==> singleton (head s) .++ tail l .== l
-- Q.E.D.
tail :: SymWord a => SList a -> SList a
tail l
 | Just (List (_:cs)) <- unliteral l
 = literal $ List cs
 | True
 = subList l 1 (length l - 1)

-- | @`singleton` x@ is the list of length 1 that contains the only value `x`.
--
-- >>> prove $ \x -> head (singleton x) .== (x :: SInteger)
-- Q.E.D.
-- >>> prove $ \x -> length (singleton x) .== 1
-- Q.E.D.
singleton :: SymWord a => SBV a -> SList a
singleton = lift1 SeqUnit (Just wrap)
  where wrap c = List [c]

-- | @`listToListAt` l offset@. List of length 1 at @offset@ in @l@. Unspecified if
-- index is out of bounds.
--
-- >>> prove $ \l1 l2 -> listToListAt (l1 .++ l2) (length l1) .== listToListAt l2 0
-- Q.E.D.
-- >>> sat $ \l -> length l .>= 2 &&& listToListAt l 0 ./= listToListAt l (length l - 1)
-- Satisfiable. Model:
--   s0 = "\NUL\NUL\EOT" :: String
listToListAt :: SymWord a => SList a -> SInteger -> SList a
listToListAt s offset = subList s offset 1

-- | @`elemAt` l i@ is the value stored at location @i@. Unspecified if
-- index is out of bounds.
--
-- >>> prove $ \i -> i .>= 0 &&& i .<= 4 ==> [1,1,1,1,1] `elemAt` i .== (1::SInteger)
-- Q.E.D.
-- >>> prove $ \l i e -> l `elemAt` i .== c ==> indexOf l (singleton e) .<= i
-- Q.E.D.
elemAt :: forall a. SymWord a => SList a -> SInteger -> SBV a
elemAt l i
  | Just (List xs) <- unliteral l, Just ci <- unliteral i, ci >= 0, ci < genericLength xs, let x = xs `genericIndex` ci
  = literal x
  | True
  = SBV (SVal kElem (Right (cache (y (l `listToListAt` i)))))
  where kElem = kindOf (undefined :: a)
        kSeq  = KList kElem
        -- This is trickier than it needs to be, but necessary since there's
        -- no SMTLib function to extract the character from a string. Instead,
        -- we form a singleton string, and assert that it is equivalent to
        -- the extracted value. See <http://github.com/Z3Prover/z3/issues/1302>
        y si st = do e <- internalVariable st kElem
                     es <- newExpr st kSeq (SBVApp (SeqOp SeqUnit) [e])
                     let esSBV = SBV (SVal kSeq (Right (cache (\_ -> return es))))
                     internalConstraint st False [] $ unSBV $ esSBV .== si
                     return e

-- | Short cut for 'elemAt'
(.!!) :: SymWord a => SList a -> SInteger -> SBV a
(.!!) = elemAt

-- | @`implode` es@ is the string of length @|es|@ containing precisely those
-- elements. Note that there is no corresponding function @explode@, since
-- we wouldn't know the length of a symbolic list.
--
-- >>> prove $ \e1 e2 e3 -> length (implode [e1, e2, e3]) .== 3
-- Q.E.D.
-- >>> prove $ \e1 e2 e3 -> map (`elemAt` (implode [e1, e2, e3])) (map literal [0 .. 2]) .== [e1, e2, e3]
-- Q.E.D.
implode :: SymWord a => [SBV a] -> SList a
implode = foldr ((.++) . singleton) (literal [])

-- | Concatenate two lists. See also `.++`.
concat :: SymWord a => SList a -> SList a -> SList a
concat x y | isConcretelyEmpty x = y
           | isConcretelyEmpty y = x
           | True                = lift2 SeqConcat (Just c) x y
           where c (List xs) (List ys) = List $ xs ++ ys

-- | Short cut for `concat`.
--
-- >>> sat $ \x y z -> length x .== 5 &&& length y .== 1 &&& x .++ y .++ z .== [1 .. 12]"
-- Satisfiable. Model:
--   s0 =  "Hello" :: String
--   s1 =      " " :: String
--   s2 = "world!" :: String
infixr 5 .++
(.++) :: SymWord a => SList a -> SList a -> SList a
(.++) = concat

-- | @`isInfixOf` sub l@. Does @l@ contain the subsequence @sub@?
--
-- >>> prove $ \l1 l2 l3 -> l2 `isInfixOf` (l1 .++ l2 .++ l3)
-- Q.E.D.
-- >>> prove $ \l1 l2 -> l1 `isInfixOf` l2 &&& l2 `isInfixOf` l1 <=> l1 .== l2
-- Q.E.D.
isInfixOf :: SymWord a => SList a -> SList a -> SBool
sub `isInfixOf` l
  | isConcretelyEmpty sub
  = literal True
  | True
  = lift2 SeqContains (Just (flip iio)) l sub -- NB. flip, since `SeqContains` takes args in rev order!
  where List xs `iio` List ys = xs `L.isInfixOf` ys

-- | @`isPrefixOf` pre l@. Is @pre@ a prefix of @l@?
--
-- >>> prove $ \l1 l2 -> l1 `isPrefixOf` (l1 .++ l2)
-- Q.E.D.
-- >>> prove $ \l1 l2 -> l1 `isPrefixOf` l2 ==> subList l2 0 (length l1) .== l1
-- Q.E.D.
isPrefixOf :: SymWord a => SList a -> SList a -> SBool
pre `isPrefixOf` l
  | isConcretelyEmpty pre
  = literal True
  | True
  = lift2 SeqPrefixOf (Just ipo) pre l
  where List xs `ipo` List ys = xs `L.isPrefixOf` ys

-- | @`isSuffixOf` suf l@. Is @suf@ a suffix of @l@?
--
-- >>> prove $ \l1 l2 -> l2 `isSuffixOf` (l1 .++ l2)
-- Q.E.D.
-- >>> prove $ \l1 l2 -> l1 `isSuffixOf` l2 ==> subList l2 (length l2 - length l1) (length l1) .== l1
-- Q.E.D.
isSuffixOf :: SymWord a => SList a -> SList a -> SBool
suf `isSuffixOf` l
  | isConcretelyEmpty suf
  = literal True
  | True
  = lift2 SeqSuffixOf (Just iso) suf l
  where List xs `iso` List ys = xs `L.isSuffixOf` ys

-- | @`take` len l@. Corresponds to Haskell's `take` on symbolic lists.
--
-- >>> prove $ \l i -> i .>= 0 ==> length (take i l) .<= i
-- Q.E.D.
take :: SymWord a => SInteger -> SList a -> SList a
take i l = ite (i .<= 0)        (literal [])
         $ ite (i .>= length l) l
         $ subList l 0 i

-- | @`drop` len s@. Corresponds to Haskell's `drop` on symbolic-lists.
--
-- >>> prove $ \l i -> length (drop i l) .<= length s
-- Q.E.D.
-- >>> prove $ \l i -> take i l .++ drop i l .== l
-- Q.E.D.
drop :: SymWord a => SInteger -> SList a -> SList a
drop i s = ite (i .>= ls) (literal [])
         $ ite (i .<= 0)  s
         $ subList s i (ls - i)
  where ls = length s

-- | @`subList` s offset len@ is the substring of @s@ at offset `offset` with length `len`.
-- This function is under-specified when the offset is outside the range of positions in @s@ or @len@
-- is negative or @offset+len@ exceeds the length of @s@. For a friendlier version of this function
-- that acts like Haskell's `take`\/`drop`, see `strTake`\/`strDrop`.
--
-- >>> prove $ \s i -> i .>= 0 &&& i .< length s ==> subList s 0 i .++ subList s i (length s - i) .== s
-- Q.E.D.
-- >>> sat  $ \i j -> subList "hello" i j .== "ell"
-- Satisfiable. Model:
--   s0 = 1 :: Integer
--   s1 = 3 :: Integer
-- >>> sat  $ \i j -> subList "hell" i j .== "no"
-- Unsatisfiable
subList :: SymWord a => SList a -> SInteger -> SInteger -> SList a
subList l offset len
  | Just (List c) <- unliteral l             -- a constant list
  , Just o  <- unliteral offset              -- a constant offset
  , Just sz <- unliteral len                 -- a constant length
  , let lc = genericLength c                 -- length of the string
  , let valid x = x >= 0 && x <= lc          -- predicate that checks valid point
  , valid o                                  -- offset is valid
  , sz >= 0                                  -- length is not-negative
  , valid $ o + sz                           -- we don't overrun
  = literal $ List $ genericTake sz $ genericDrop o c
  | True                                     -- either symbolic, or something is out-of-bounds
  = lift3 SeqSubseq Nothing l offset len

-- | @`replace` l src dst@. Replace the first occurrence of @src@ by @dst@ in @s@
--
-- >>> prove $ \l -> replace "hello" l "world" .== "world" ==> l .== "hello"
-- Q.E.D.
-- >>> prove $ \l1 l2 l3 -> length l2 .> length l1 ==> replace l1 l2 l3 .== l1
-- Q.E.D.
replace :: SymWord a => SList a -> SList a -> SList a -> SList a
replace l src dst
  | Just (List b) <- unliteral src, P.null b   -- If src is null, simply prepend
  = dst .++ l
  | Just (List a) <- unliteral l
  , Just (List b) <- unliteral src
  , Just (List c) <- unliteral dst
  = literal $ List $ walk a b c
  | True
  = lift3 SeqReplace Nothing l src dst
  where walk haystack needle newNeedle = go haystack   -- note that needle is guaranteed non-empty here.
           where go []       = []
                 go i@(c:cs)
                  | needle `L.isPrefixOf` i = newNeedle ++ genericDrop (genericLength needle :: Integer) i
                  | True                    = c : go cs

-- | @`indexOf` l sub@. Retrieves first position of @sub@ in @l@, @-1@ if there are no occurrences.
-- Equivalent to @`offsetIndexOf` l sub 0@.
--
-- >>> prove $ \l i -> i .> 0 &&& i .< length l ==> indexOf l (subList l i 1) .<= i
-- Q.E.D.
-- >>> prove $ \l i -> i .> 0 &&& i .< length l ==> indexOf s (subList l i 1) .== i
-- Falsifiable. Counter-example:
--   s0 = "\NUL\NUL\NUL\NUL\NUL" :: String
--   s1 =                      3 :: Integer
-- >>> prove $ \s1 s2 -> length s2 .> length s1 ==> indexOf s1 s2 .== -1
-- Q.E.D.
indexOf :: SymWord a => SList a -> SList a -> SInteger
indexOf s sub = offsetIndexOf s sub 0

-- | @`offsetIndexOf` l sub offset@. Retrieves first position of @sub@ at or
-- after @offset@ in @l@, @-1@ if there are no occurrences.
--
-- >>> prove $ \l sub -> offsetIndexOf l sub 0 .== indexOf l sub
-- Q.E.D.
-- >>> prove $ \l sub i -> i .>= length s &&& length sub .> 0 ==> offsetIndexOf l sub i .== -1
-- Q.E.D.
-- >>> prove $ \l sub i -> i .> length l ==> offsetIndexOf l sub i .== -1
-- Q.E.D.
offsetIndexOf :: SymWord a => SList a -> SList a -> SInteger -> SInteger
offsetIndexOf s sub offset
  | Just (List c) <- unliteral s        -- a constant list
  , Just (List n) <- unliteral sub      -- a constant search pattern
  , Just o        <- unliteral offset   -- at a constant offset
  , o >= 0, o <= genericLength c        -- offset is good
  = case [i | (i, t) <- zip [o ..] (L.tails (genericDrop o c)), n `L.isPrefixOf` t] of
      (i:_) -> literal i
      _     -> -1
  | True
  = lift3 SeqIndexOf Nothing s sub offset

-- | Lift a unary operator over strings.
lift1 :: forall a b. (SymWord a, SymWord b) => SeqOp -> Maybe (a -> b) -> SBV a -> SBV b
lift1 w mbOp a
  | Just cv <- concEval1 mbOp a
  = cv
  | True
  = SBV $ SVal k $ Right $ cache r
  where k = kindOf (undefined :: b)
        r st = do swa <- sbvToSW st a
                  newExpr st k (SBVApp (SeqOp w) [swa])

-- | Lift a binary operator over strings.
lift2 :: forall a b c. (SymWord a, SymWord b, SymWord c) => SeqOp -> Maybe (a -> b -> c) -> SBV a -> SBV b -> SBV c
lift2 w mbOp a b
  | Just cv <- concEval2 mbOp a b
  = cv
  | True
  = SBV $ SVal k $ Right $ cache r
  where k = kindOf (undefined :: c)
        r st = do swa <- sbvToSW st a
                  swb <- sbvToSW st b
                  newExpr st k (SBVApp (SeqOp w) [swa, swb])

-- | Lift a ternary operator over strings.
lift3 :: forall a b c d. (SymWord a, SymWord b, SymWord c, SymWord d) => SeqOp -> Maybe (a -> b -> c -> d) -> SBV a -> SBV b -> SBV c -> SBV d
lift3 w mbOp a b c
  | Just cv <- concEval3 mbOp a b c
  = cv
  | True
  = SBV $ SVal k $ Right $ cache r
  where k = kindOf (undefined :: d)
        r st = do swa <- sbvToSW st a
                  swb <- sbvToSW st b
                  swc <- sbvToSW st c
                  newExpr st k (SBVApp (SeqOp w) [swa, swb, swc])

-- | Concrete evaluation for unary ops
concEval1 :: (SymWord a, SymWord b) => Maybe (a -> b) -> SBV a -> Maybe (SBV b)
concEval1 mbOp a = literal <$> (mbOp <*> unliteral a)

-- | Concrete evaluation for binary ops
concEval2 :: (SymWord a, SymWord b, SymWord c) => Maybe (a -> b -> c) -> SBV a -> SBV b -> Maybe (SBV c)
concEval2 mbOp a b = literal <$> (mbOp <*> unliteral a <*> unliteral b)

-- | Concrete evaluation for ternary ops
concEval3 :: (SymWord a, SymWord b, SymWord c, SymWord d) => Maybe (a -> b -> c -> d) -> SBV a -> SBV b -> SBV c -> Maybe (SBV d)
concEval3 mbOp a b c = literal <$> (mbOp <*> unliteral a <*> unliteral b <*> unliteral c)

-- | Is the string concretely known empty?
isConcretelyEmpty :: SymWord a => SList a -> Bool
isConcretelyEmpty sl | Just (List l) <- unliteral sl = P.null l
                     | True                          = False
