{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}

module Data.Struct.TH (makeStruct) where

import           Control.Monad (when, zipWithM)
import           Control.Monad.Primitive (PrimMonad, PrimState)
import           Data.Struct
import           Data.Struct.Internal (Dict(Dict))
import           Data.List (groupBy)
import           Language.Haskell.TH
import           Language.Haskell.TH.Syntax (VarStrictType)

#ifdef HLINT
{-# ANN module "HLint: ignore Use ." #-}
#endif

data StructRep = StructRep
  { srState       :: Name
  , srName        :: Name
  , srTyVars      :: [TyVarBndr]
  , srDerived     :: [Name]
  , srCxt         :: Cxt
  , srConstructor :: Name
  , srMembers :: [Member]
  } deriving Show

data Member
  = BoxedField Name Type
  | UnboxedField Name Type
  | Slot Name Type
  deriving Show

memberName :: Member -> Name
memberName (BoxedField   n _) = n
memberName (UnboxedField n _) = n
memberName (Slot         n _) = n

isUnboxedField :: Member -> Bool
isUnboxedField UnboxedField{} = True
isUnboxedField _              = False


-- | Generate allocators, slots, fields, unboxed fields, Eq instances,
-- and Struct instances for the given "data types".
--
-- Inputs are expected to be "data types" parameterized by a state
-- type. Strict fields are considered to be slots, Non-strict fields
-- are considered to be boxed types, Unpacked fields are considered
-- to be unboxed primitives.
--
-- The data type should use record syntax and have a single constructor.
-- The field names will be used to generate slot, field, and unboxedField
-- values of the same name.
--
-- An allocator for the struct is generated by prefixing "alloc" to the
-- data type name.
makeStruct :: DecsQ -> DecsQ
makeStruct dsq =
  do ds   <- dsq
     reps <- traverse computeRep ds
     ds's <- traverse generateCode reps
     return (concat ds's)

mkAllocName :: StructRep -> Name
mkAllocName rep = mkName ("alloc" ++ nameBase (srName rep))

mkInitName :: StructRep -> Name
mkInitName rep = mkName ("new" ++ nameBase (srName rep))

------------------------------------------------------------------------
-- Input validation
------------------------------------------------------------------------

computeRep :: Dec -> Q StructRep
computeRep (DataD c n vs cs ds) =
  do state <- validateStateType vs
     (conname, confields) <- validateContructor cs
     members <- traverse (validateMember state) confields

     return StructRep
       { srState = state
       , srName  = n
       , srTyVars = vs
       , srConstructor = conname
       , srMembers = members
       , srDerived = ds
       , srCxt = c
       }
computeRep _ = fail "makeStruct expects a datatype declaration"

-- | Check that only a single data constructor was provided and
-- that it was a record constructor.
validateContructor :: [Con] -> Q (Name,[VarStrictType])
validateContructor [RecC name fields] = return (name,fields)
validateContructor [_] = fail "Expected a record constructor"
validateContructor xs = fail ("Expected 1 constructor, got " ++ show (length xs))

-- A struct type's final type variable should be suitable for
-- use as the ('PrimState' m) argument.
validateStateType :: [TyVarBndr] -> Q Name
validateStateType xs =
  do when (null xs) (fail "state type expected but no type variables found")
     case last xs of
       PlainTV n -> return n
       KindedTV n k
         | k == starK -> return n
         | otherwise  -> fail "state type should have kind *"


-- | Figure out which record fields are Slots and which are
-- Fields. Slots will have types ending in the state type
validateMember :: Name -> VarStrictType -> Q Member
validateMember _ (fieldname,NotStrict,fieldtype) =
  return (BoxedField fieldname fieldtype)
validateMember s (fieldname,IsStrict,fieldtype) =
  do f <- unapplyType fieldtype s
     return (Slot fieldname f)
validateMember _ (fieldname,Unpacked,fieldtype) =
  return (UnboxedField fieldname fieldtype)

unapplyType :: Type -> Name -> Q Type
unapplyType (AppT f (VarT x)) y | x == y = return f
unapplyType _ _ = fail "Unable to match state type of slot"

------------------------------------------------------------------------
-- Code generation
------------------------------------------------------------------------

generateCode :: StructRep -> DecsQ
generateCode rep = concat <$> sequence
  [ generateDataType rep
  , generateStructInstance rep
  , generateMembers rep
  , generateNew rep
  , generateAlloc rep
  ]

-- Generates: newtype TyCon a b c s = DataCon (Object s)
generateDataType :: StructRep -> DecsQ
generateDataType rep = sequence
  [ newtypeD (return (srCxt rep)) (srName rep) (srTyVars rep)
      (normalC
         (srConstructor rep)
         [ strictType
             notStrict
             [t| Object $(varT (srState rep)) |]
         ])
      (srDerived rep)
  ]

-- | Type of the object not applied to a state type. This
-- should have kind * -> *
repType1 :: StructRep -> TypeQ
repType1 rep = repTypeHelper (srName rep) (init (srTyVars rep))

-- | Type of the object as originally declared, fully applied.
repType :: StructRep -> TypeQ
repType rep = repTypeHelper (srName rep) (srTyVars rep)

repTypeHelper :: Name -> [TyVarBndr] -> TypeQ
repTypeHelper c vs = foldl appT (conT c) (tyVarBndrT <$> vs)

-- Construct a 'TypeQ' from a 'TyVarBndr'
tyVarBndrT :: TyVarBndr -> TypeQ
tyVarBndrT (PlainTV  n  ) = varT n
tyVarBndrT (KindedTV n k) = sigT (varT n) k

generateStructInstance :: StructRep -> DecsQ
generateStructInstance rep =
  [d| instance Struct $(repType1 rep) where struct = Dict
      instance Eq     $(repType  rep) where (==)   = eqStruct
    |]

-- generates: allocDataCon = alloc <n>
generateAlloc :: StructRep -> DecsQ
generateAlloc rep =
  do mName <- newName "m"
     let m = varT mName
         n = length (groupBy isNeighbor (srMembers rep))
         allocName = mkAllocName rep
     sequence
       [ sigD allocName $ forallRepT rep $ forallT [PlainTV mName] (cxt [])
           [t| PrimMonad $m => $m ( $(repType1 rep) (PrimState $m) ) |]
       , simpleValD allocName [| alloc n |]
       ]


-- generates:
-- newDataCon a .. = do this <- alloc <n>; set field1 this a; ...; return this
generateNew :: StructRep -> DecsQ
generateNew rep | hasUnboxedFields rep = return []
generateNew rep =
  do this <- newName "this"
     args <- traverse (newName . nameBase . memberName) (srMembers rep)

     let count = length args
         name = mkInitName rep
         body = doE
                -- allocate struct
              $ bindS (varP this) [| alloc count |]

                -- initialize each member
              : [ noBindS (initialize (varE this) (varE n) m)
                | (n,m) <- zip args (srMembers rep) ]

                -- return initialized struct
             ++ [ noBindS [| return $(varE this) |] ]

     sequence
       [ sigD name (newStructType rep)
       , funD name [ clause (varP <$> args) (normalB body) [] ]
       ]


hasUnboxedFields :: StructRep -> Bool
hasUnboxedFields = any isUnboxedField . srMembers


initialize :: ExpQ -> ExpQ -> Member -> ExpQ
initialize this arg (BoxedField n _) = [| setField $(varE n) $this $arg |]
initialize this arg (Slot       n _) = [| set      $(varE n) $this $arg |]
initialize _ _ _ = fail "Unboxed initializers not supported"

-- | The type of the struct initializer is complicated enough to
-- pull it out here.
-- generates:
-- PrimMonad m => field1 -> field2 -> ... -> m (TyName a b ... (PrimState m))
newStructType :: StructRep -> TypeQ
newStructType rep =
  do mName <- newName "m"
     let m = varT mName
         s = [t| PrimState $m |]
         obj = repType1 rep

         memberType (BoxedField   _ t) = return t
         memberType (UnboxedField _ t) = return t
         memberType (Slot         _ f) = [t| $(return f) $s |]

         r = foldr (-->)
               [t| $m ($obj $s) |]
               (memberType <$> srMembers rep)

     forallT [PlainTV mName] (cxt []) $ forallRepT rep
       [t| PrimMonad $m => $r |]

-- generates a slot, field, or unboxedField definition per member
generateMembers :: StructRep -> DecsQ
generateMembers rep
  = concat <$>
    zipWithM
      (generateMember1 rep)
      [0..]
      (groupBy isNeighbor (srMembers rep))

isNeighbor :: Member -> Member -> Bool
isNeighbor a b = isUnboxedField a && isUnboxedField b

------------------------------------------------------------------------

generateMember1 :: StructRep -> Int -> [Member] -> DecsQ

-- generates: fieldname = field <n>
generateMember1 rep n [BoxedField fieldname fieldtype] =
  sequence
    [ sigD fieldname $ forallRepT rep
        [t| Field $(repType1 rep) $(return fieldtype) |]
    , simpleValD fieldname [| field n |]
    ]

-- generates: slotname = slot <n>
generateMember1 rep n [Slot slotname slottype] =
  sequence
    [ sigD slotname $ forallRepT rep
        [t| Slot $(repType1 rep) $(return slottype) |]
    , simpleValD slotname [| slot n |]
    ]

-- It the first type patterns didn't hit then we expect a list
-- of unboxed fields due to the call to groupBy in generateMembers
-- generates: fieldname = unboxedField <n>
generateMember1 rep n us = sequence
  [ d
  | (i,UnboxedField fieldname fieldtype)
       <- zip [0 :: Int ..] us
  , d <- [ sigD fieldname $
             forallRepT rep
               [t| Field $(repType1 rep) $(return fieldtype) |]
         , simpleValD fieldname [| unboxedField n i |]
         ]
  ]

------------------------------------------------------------------------

-- Simple use of 'valD' bind an expression to a name
simpleValD :: Name -> ExpQ -> DecQ
simpleValD var val = valD (varP var) (normalB val) []

-- Quantifies over all of the type variables in a struct data type
-- except the state variable which is likely to be ('PrimState' s)
forallRepT :: StructRep -> TypeQ -> TypeQ
forallRepT rep = forallT (init (srTyVars rep)) (cxt [])

(-->) :: TypeQ -> TypeQ -> TypeQ
f --> x = arrowT `appT` f `appT` x
