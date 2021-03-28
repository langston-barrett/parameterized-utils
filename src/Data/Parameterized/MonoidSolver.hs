{-|
Description : A solver for type-level equations in monoids
Copyright   : (c) Galois, Inc 2021
Maintainer  : Langston Barrett

Implementation of section 6 of \"A well-known representation of monoids and its
application to the function \'vector reverse\'\" by Wouter Swierstra.
-}

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Data.Parameterized.MonoidSolver
  ( solve
  , MonoidExpr
  , type EUnit
  , type EVar
  , type (:<>:)
  , MERepr(..)
  ) where

import Data.Kind (Type)
import Data.Proxy (Proxy(..))
import Data.Type.Equality (type (:~:)(Refl))
import GHC.TypeLits (Nat, Symbol, AppendSymbol)

import Data.Parameterized.Classes (KnownRepr(..))
import Data.Parameterized.Ctx (Ctx, type (<+>), EmptyCtx)
import Data.Parameterized.NatRepr (type (+), plusAssoc)

----------------------------------------------------------------------
-- Class
--

-- | 'Op' corresponds to @Add@ from the paper.
type family Op k (m1 :: k) (m2 :: k) :: k
-- | 'Unit' corresponds to @Zero@ from the paper.
type family Unit k :: k

class TypeLevelMonoid (k :: Type) where
  idl :: forall proxy n. proxy n -> Op k (Unit k) n :~: n
  idr :: forall proxy n. proxy n -> Op k n (Unit k) :~: n
  assoc ::
    forall proxy n m l.
    proxy n ->
    proxy m ->
    proxy l ->
    Op k n (Op k m l) :~: Op k (Op k n m) l

----------------------------------------------------------------------
-- Normalization
--

-- | Type level only
data MonoidExpr k
  = EUnit
  | EVar k
  | (MonoidExpr k) :<>: (MonoidExpr k)

-- Since MonoidExpr is type-level only, ticks aren't necessary for disambiguation
type EUnit = 'EUnit
type EVar m = 'EVar m
type me1 :<>: me2 = me1 ':<>: me2

data MERepr (k :: Type) (me :: MonoidExpr k) where
  EUnitRepr :: MERepr k 'EUnit
  EVarRepr :: Proxy n -> MERepr k ('EVar n)
  EOpRepr ::
    MERepr k me1 ->
    MERepr k me2 ->
    MERepr k (me1 :<>: me2)

type family Eval (k :: Type) (me :: MonoidExpr k) :: k where
  Eval k 'EUnit = Unit k
  Eval k ('EVar m) = m
  Eval k (me1 :<>: me2) = Op k (Eval k me1) (Eval k me2)

-- | Defunctionalization - inspired by \"singletons\", and with a similar naming
-- scheme
data TyFun a b
type a ~> b = TyFun a b -> Type
type family Apply (f :: a ~> b) (x :: a) :: b

data IdSym1 :: MonoidExpr m ~> MonoidExpr m
data EOpSym0 :: MonoidExpr m ~> (MonoidExpr m ~> MonoidExpr m)
data EOpSym1 (me :: MonoidExpr m) :: MonoidExpr m ~> MonoidExpr m
data ComposeDiffSym0 :: MonoidExpr m ~> (MonoidExpr m ~> (MonoidExpr m ~> MonoidExpr m))
data ComposeDiffSym1 (me :: MonoidExpr m) :: MonoidExpr m ~> (MonoidExpr m ~> MonoidExpr m)
data ComposeDiffSym2 (me1 :: MonoidExpr m) (me2 :: MonoidExpr m) :: MonoidExpr m ~> MonoidExpr m

type instance Apply IdSym1 me = me
type instance Apply EOpSym0 me = EOpSym1 me
type instance Apply (EOpSym1 me1) (me2 :: MonoidExpr m) = me1 :<>: me2
-- TODO: generalize to (higher-order) compose?
type instance Apply ComposeDiffSym0 me = ComposeDiffSym1 me
type instance Apply (ComposeDiffSym1 me1) me2 = ComposeDiffSym2 me1 me2
type instance Apply (ComposeDiffSym2 me1 me2) me3 = Apply (Diff me1) (Apply (Diff me2) me3)

-- | The \"difference list\"/Caley embedding representation of monoid
-- expressions, corresponds to the bracket operator in the paper.
type family Diff (me :: MonoidExpr m) :: MonoidExpr m ~> MonoidExpr m where
  Diff (me1 :<>: me2) = ComposeDiffSym2 me1 me2
  Diff 'EUnit = IdSym1
  Diff ('EVar m) = EOpSym1 ('EVar m)

-- | 'UnDiff' corresponds to "reify" from the paper.
type family UnDiff (diff :: MonoidExpr m ~> MonoidExpr m) :: MonoidExpr m where
  UnDiff diff = Apply diff 'EUnit

type family Normalize (me :: MonoidExpr m) :: MonoidExpr m where
  Normalize me = UnDiff (Diff me)

-- | Note on termination: The one recursive call to this function is strictly
-- decreasing on its first argument. This function is mutually recursive with
-- 'normalizeSound' and recursive calls to that function are made on the second
-- argument, but calls to this function *from* 'normalizeSound' are on strict
-- subexpressions of its argument.
normalizeLemma ::
  forall k me1 me2.
  TypeLevelMonoid k =>
  MERepr k me1 ->
  MERepr k me2 ->
  Eval k (Apply (Diff me1) (Apply (Diff me2) 'EUnit)) :~:
    Op k (Eval k me1) (Eval k me2)
normalizeLemma mer1 mer2 =
  case mer1 of
    EUnitRepr ->
      case idl (Proxy :: Proxy (Eval k me2)) of
        Refl ->
          case norm mer2 of
            Refl -> Refl
    EVarRepr {} ->
      case norm mer2 of
        Refl -> Refl
    EOpRepr (mer1' :: MERepr k me1') (mer2' :: MERepr k me2') ->
      case normalizeLemma mer1' (EOpRepr mer2' mer2) of
        Refl ->
              assoc (Proxy :: Proxy (Eval k me1')) (Proxy :: Proxy (Eval k me2')) (Proxy :: Proxy (Eval k me2))
  where
    norm :: MERepr k me -> Eval k (Normalize me) :~: Eval k me
    norm = normalizeSound

normalizeSound ::
  TypeLevelMonoid k =>
  MERepr k me ->
  Eval k (Normalize me) :~: Eval k me
normalizeSound =
  \case
    EUnitRepr -> Refl
    EVarRepr (sing :: Proxy n) -> idr sing
    EOpRepr (mer1 :: MERepr k me1) (mer2 :: MERepr k me2) ->
      normalizeLemma mer1 mer2

-- | Because of the construction of 'Normalize', the equality constraint always
-- holds between 'MERepr' terms that are convertible with the monoid laws.
solve ::
  ( TypeLevelMonoid k
  , Eval k (Normalize me1) ~ Eval k (Normalize me2)
  )
  =>
  MERepr k me1 ->
  MERepr k me2 ->
  Eval k me1 :~: Eval k me2
solve repr1 repr2 =
  case (normalizeSound repr1, normalizeSound repr2) of
    (Refl, Refl) -> Refl

----------------------------------------------------------------------
-- KnownRepr
--

instance KnownRepr (MERepr k) 'EUnit where
  knownRepr = EUnitRepr

instance KnownRepr (MERepr k) ('EVar n) where
  knownRepr = EVarRepr (Proxy :: Proxy n)

instance
  ( KnownRepr (MERepr k) me1
  , KnownRepr (MERepr k) me2
  ) => KnownRepr (MERepr k) (me1 ':<>: me2) where
  knownRepr = EOpRepr knownRepr knownRepr

----------------------------------------------------------------------
-- Instances
--

type instance Op Nat n1 n2 = n1 + n2
type instance Unit Nat = 0

instance TypeLevelMonoid Nat where
  idl = const Refl
  idr = const Refl
  assoc proxy1 proxy2 proxy3 =
    case plusAssoc proxy1 proxy2 proxy3 of
      Refl -> Refl

type instance Op (Ctx k) c1 c2 = c1 <+> c2
type instance Unit (Ctx k) = EmptyCtx

instance TypeLevelMonoid (Ctx k) where
  idl = undefined -- TODO
  idr = const Refl
  assoc _ _ _ = undefined -- TODO

type family Append (l1 :: [a]) (l2 :: [a]) :: [a] where
  Append '[] ys = ys
  Append xs '[] = xs
  Append (x ': xs) ys  = x ': Append xs ys

type instance Op [a] n1 n2 = Append n1 n2
type instance Unit [a] = '[]

instance TypeLevelMonoid [a] where
  idl = const Refl
  idr = const Refl
  assoc _ _ _ = undefined -- TODO

type instance Op Symbol n1 n2 = AppendSymbol n1 n2
type instance Unit Symbol = ""

instance TypeLevelMonoid Symbol where
  idl = const Refl
  idr = const Refl
  -- This probably just has to be (unsafeCoerce Refl)...
  assoc _ _ _ = undefined -- TODO

----------------------------------------------------------------------
-- Examples
--

_ex ::
  forall n m l.
  Proxy n ->
  Proxy m ->
  Proxy l ->
  n + (m + l) :~: (n + m) + l
_ex _ _ _ =
  let e1 = knownRepr :: MERepr Nat ('EVar n :<>: ('EVar m :<>: 'EVar l))
      e2 = knownRepr :: MERepr Nat (('EVar n :<>: 'EVar m) :<>: 'EVar l)
  in solve e1 e2

assoc5 ::
  Proxy a ->
  Proxy b ->
  Proxy c ->
  Proxy d ->
  Proxy e ->
  a + (b + (c + (d + e))) :~: (((a + b) + c) + d) + e
assoc5 a b c d e =
  let e1 = EOpRepr (EVarRepr a) (EOpRepr (EVarRepr b) (EOpRepr (EVarRepr c) (EOpRepr (EVarRepr d) (EVarRepr e))))
      e2 = EOpRepr (EOpRepr (EOpRepr (EOpRepr (EVarRepr a) (EVarRepr b)) (EVarRepr c)) (EVarRepr d)) (EVarRepr e)
  in solve e1 e2

_assoc5Nat ::
  Proxy a ->
  Proxy b ->
  Proxy c ->
  Proxy d ->
  Proxy e ->
  (a + (b + (c + (d + e)))) :~: ((((a + b) + c) + d) + e)
_assoc5Nat a b c d e =
  case assoc5 a b c d e of
    Refl -> Refl

-- Doesn't typecheck:
--
-- _assoc5Nat' ::
--   proxy a ->
--   proxy b ->
--   proxy c ->
--   proxy d ->
--   proxy e ->
--   (a + (b + (c + (d + e)))) :~: ((((a + b) + c) + d) + e)
-- _assoc5Nat' _ _ _ _ _ = Refl
