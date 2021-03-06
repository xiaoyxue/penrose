-- | The GenOptProblem module performs several passes on the translation generated
-- by the Style compiler to generate the initial state (fields and GPIs) and optimization problem
-- (objectives, constraints, and computations) specified by the Substance/Style pair.
{-# OPTIONS_HADDOCK prune #-}
{-# LANGUAGE AllowAmbiguousTypes       #-}
{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE UnicodeSyntax             #-}

-- Mostly for autodiff
module Penrose.GenOptProblem where

import           Control.Monad         (foldM, forM_)
import qualified Data.Aeson            as A
import           Data.Array            (assocs)
import           Data.Either           (partitionEithers)
import qualified Data.Graph            as Graph
import           Data.List             (foldl', intercalate, minimumBy,
                                        partition)
import qualified Data.Map.Strict       as M
import qualified Data.Maybe            as DM (fromJust)
import qualified Data.Set              as Set
import           Debug.Trace
import           GHC.Float             (double2Float, float2Double)
import           GHC.Generics
import qualified Numeric.LinearAlgebra as L
import           Penrose.Env
import           Penrose.Functions
import           Penrose.Shapes
import           Penrose.Style
import qualified Penrose.Substance     as C
import qualified Penrose.SubstanceJSON as J
import           Penrose.Transforms
import           Penrose.Util
import           System.Console.Pretty (Color (..), Style (..), bgColor, color,
                                        style, supportsPretty)
import           System.IO.Unsafe      (unsafePerformIO)
import           System.Random
import           Text.Show.Pretty      (pPrint, ppShow)

-- default (Int, Float)
-------------------- Type definitions
type StyleOptFn = (String, [Expr]) -- Objective or constraint

data OptType
  = Objfn
  | Constrfn
  deriving (Show, Eq)

data Fn = Fn
  { fname   :: String
  , fargs   :: [Expr]
  , optType :: OptType
  } deriving (Show, Eq)

data FnDone a = FnDone
  { fname_d   :: String
  , fargs_d   :: [ArgVal a]
  , optType_d :: OptType
  } deriving (Show, Eq)

-- A map from the varying path to its value, used to look up values in the translation
type VaryMap a = M.Map Path (TagExpr a)

------- State type definitions
-- Stores the last EP varying state (that is, the state when the unconstrained opt last converged)
type LastEPstate = [Double] -- Note: NOT polymorphic (due to system slowness with polymorphism)

data OptStatus
  = NewIter
  | UnconstrainedRunning LastEPstate
  | UnconstrainedConverged LastEPstate
  | EPConverged

instance Show OptStatus where
  show NewIter = "New iteration"
  show (UnconstrainedRunning lastEPstate) =
    "Unconstrained running" -- with last EP state:\n" ++ show lastEPstate
  show (UnconstrainedConverged lastEPstate) =
    "Unconstrained converged" -- with last EP state:\n" ++ show lastEPstate
  show EPConverged = "EP converged"

instance Eq OptStatus where
  x == y =
    case (x, y) of
      (NewIter, NewIter)                                   -> True
      (EPConverged, EPConverged)                           -> True
      (UnconstrainedRunning a, UnconstrainedRunning b)     -> a == b
      (UnconstrainedConverged a, UnconstrainedConverged b) -> a == b
      (_, _)                                               -> False

data Params = Params
  { weight    :: Float
  , optStatus :: OptStatus
                    --    overallObjFn :: forall a . (Autofloat a) => StdGen -> a -> [a] -> a,
  , bfgsInfo  :: BfgsParams
  }

instance Show Params where
  show p =
    "Weight: " ++ show (weight p) ++ " | Opt status: " ++ show (optStatus p)
                             -- ++ "\nBFGS info:\n" ++ show (bfgsInfo p)

data BfgsParams = BfgsParams
  { lastState        :: Maybe [Double] -- x_k
  , lastGrad         :: Maybe [Double] -- gradient of f(x_k)
  , invH             :: Maybe [[Double]] -- (BFGS only) estimate of the inverse of the hessian, H_k (TODO: are these indices right?)
  , s_list           :: [[Double]] -- (L-BFGS only) s_i (state difference) from k-1 to k-m
  , y_list           :: [[Double]] -- (L-BFGS only) y_i (grad difference) from k-1 to k-m
  , numUnconstrSteps :: Int -- (L-BFGS only) number of steps so far, starting at 0
  , memSize          :: Int -- (L-BFGS only) number of vectors to retain
  }

-- data BfgsParams = BfgsParams {
--      lastState :: Maybe (L.Vector L.R), -- x_k
--      lastGrad :: Maybe (L.Vector L.R),  -- gradient of f(x_k)
--      invH :: Maybe (L.Matrix L.R),  -- (BFGS only) estimate of the inverse of the hessian, H_k (TODO: are these indices right?)
--      s_list :: [L.Vector L.R], -- (L-BFGS only) s_i (state difference) from k-1 to k-m
--      y_list :: [L.Vector L.R],  -- (L-BFGS only) y_i (grad difference) from k-1 to k-m
--      numUnconstrSteps :: Int, -- (L-BFGS only) number of steps so far, starting at 0
--      memSize :: Int -- (L-BFGS only) number of vectors to retain
-- }
instance Show BfgsParams where
  show s =
    "\nBFGS params:\n" ++
    "\nlastState: \n" ++
    show (lastState s) ++
    "\nlastGrad: \n" ++
    show (lastGrad s) ++
    "\ninvH: \n" ++
    show (invH s) ++
                  -- This is a lot of output (can be 2 * defaultBfgsMemSize * state size)
                  -- "\ns_list:\n" ++ show (s_list s) ++
                  -- "\ny_list:\n" ++ show (y_list s) ++
    "\nlength of s_list:\n" ++
    (show $ length $ s_list s) ++
    "\nlength of y_list:\n" ++
    (show $ length $ y_list s) ++
    "\nnumUnconstrSteps:\n" ++
    show (numUnconstrSteps s) ++ "\nmemSize:\n" ++ show (memSize s) ++ "\n"

defaultBfgsMemSize :: Int
defaultBfgsMemSize = 17

-- Shorter memory seems to work better in practice; Nocedal says between 3 and 30 is a good `m` (see p227)
-- but the choice of `m` is also problem-dependent
defaultBfgsParams =
  BfgsParams
  { lastState = Nothing
  , lastGrad = Nothing
  , invH = Nothing
  , s_list = []
  , y_list = []
  , numUnconstrSteps = 0
  , memSize = defaultBfgsMemSize
  }

type PolicyState = String -- Should this include the functions that it returned last time?

type Policy = [Fn] -> [Fn] -> PolicyParams -> (Maybe [Fn], PolicyState)

data PolicyParams = PolicyParams
  { policyState :: String
  , policySteps :: Int
  , currFns     :: [Fn]
  }

instance Show PolicyParams where
  show p =
    "Policy state: " ++
    policyState p ++ " | Policy steps: " ++ show (policySteps p)
                          -- ++ "\nFunctions:\n" ++ ppShow (currFns p)

data OptMethod
  = Newton
  | BFGS
  | LBFGS
  | GradientDescent
  deriving (Eq, Show, Generic)

instance A.ToJSON OptMethod where
  toEncoding = A.genericToEncoding A.defaultOptions

instance A.FromJSON OptMethod

data OptConfig = OptConfig
  { optMethod :: OptMethod
  } deriving (Eq, Show, Generic)

defaultOptConfig = OptConfig {optMethod = LBFGS}

instance A.ToJSON OptConfig where
  toEncoding = A.genericToEncoding A.defaultOptions

instance A.FromJSON OptConfig

data State = State
  { shapesr            :: [Shape Double]
  , shapePaths         :: [Path]
  , shapeOrdering      :: [String]
  , shapeProperties    :: [(String, Field, Property)]
  , transr             :: Translation Double
  , varyingPaths       :: [Path]
  , uninitializedPaths :: [Path]
  , pendingPaths       :: [Path]
  , varyingState       :: [Double] -- Note: NOT polymorphic
  , paramsr            :: Params
  , objFns             :: [Fn]
  , constrFns          :: [Fn]
  , rng                :: StdGen
  , selectorMatches    :: [Int]
                    --  policyFn :: Policy,
  , policyParams       :: PolicyParams
  , oConfig            :: OptConfig
  }

instance Show State where
  show s =
    "Shapes: \n" ++
    ppShow (shapesr s) ++
    "\nShape names: \n" ++
    ppShow (shapePaths s) ++
    "\nTranslation: \n" ++
    ppShow (transr s) ++
    "\nVarying paths: \n" ++
    ppShow (varyingPaths s) ++
    "\nUninitialized paths: \n" ++
    ppShow (uninitializedPaths s) ++
    "\nVarying state: \n" ++
    ppShow (varyingState s) ++
    "\nParams: \n" ++
    ppShow (paramsr s) ++
    "\nObjective Functions: \n" ++
    ppShowList (objFns s) ++
    "\nConstraint Functions: \n" ++ ppShowList (constrFns s)

-- Reimplementation of 'ppShowList' from pretty-show. Not sure why it cannot be imported at all
ppShowList = concatMap ((++) "\n" . ppShow)

--------------- Constants
-- For evaluating expressions
startingIteration, maxEvalIteration :: Int
startingIteration = 0

maxEvalIteration = 500 -- Max iteration depth in case of cycles

evalIterRange :: (Int, Int)
evalIterRange = (startingIteration, maxEvalIteration)

initRng :: StdGen
initRng = mkStdGen seed
  where
    seed = 17 -- deterministic RNG with seed

-- initRng = unsafePerformIO newStdGen -- random RNG with seed
--------------- Parameters used in optimization
-- Should really be in Optimizer, but need to fix module import structure
constrWeight :: Floating a => a
constrWeight = 10 ^ 4

-- for use in barrier/penalty method (interior/exterior point method)
-- seems if the point starts in interior + weight starts v small and increases, then it converges
-- not quite: if the weight is too small then the constraint will be violated
initWeight :: Autofloat a => a
-- initWeight = 10 ** (-5)
-- Converges very fast w/ constraints removed (function-composition.sub)
-- initWeight = 0
-- Steps very slowly with a higher weight; does not seem to converge but looks visually OK (function-composition.sub)
-- initWeight = 1
initWeight = 10 ** (-3)

policyToUse :: Policy
policyToUse = optimizeSumAll

-- policyToUse = optimizeConstraintsThenObjectives
-- policyToUse = optimizeConstraints
-- policyToUse = optimizeObjectives
--------------- Utility functions
declaredVarying :: (Autofloat a) => TagExpr a -> Bool
declaredVarying (OptEval (AFloat Vary)) = True
declaredVarying _                       = False

isVarying :: (Autofloat a) => Expr -> Bool
isVarying (AFloat Vary) = True
isVarying _ = False

sumMap :: Floating b => (a -> b) -> [a] -> b -- common pattern in objective functions
sumMap f l = sum $ map f l

-- TODO: figure out what to do with sty vars
mkPath :: [String] -> Path
mkPath [name, field] = FieldPath (BSubVar (VarConst name)) field
mkPath [name, field, property] =
  PropertyPath (BSubVar (VarConst name)) field property

pathToList :: Path -> [String]
pathToList (FieldPath (BSubVar (VarConst name)) field) = [name, field]
pathToList (PropertyPath (BSubVar (VarConst name)) field property) =
  [name, field, property]
pathToList _ = error "pathToList should not handle Sty vars"

isFieldOrAccessPath :: Path -> Bool
isFieldOrAccessPath (FieldPath _ _)      = True
isFieldOrAccessPath (AccessPath (FieldPath _ _) _) = True
isFieldOrAccessPath (AccessPath (PropertyPath _ _ _) _) = False
isFieldOrAccessPath (PropertyPath _ _ _) = False

bvarToString :: BindingForm -> String
bvarToString (BSubVar (VarConst s)) = s
bvarToString (BStyVar (StyVar s))   = s -- For namespaces
             -- error ("bvarToString: cannot handle Style variable: " ++ show v)

getShapeName :: String -> Field -> String
getShapeName subName field = subName ++ "." ++ field

-- For varying values to be inserted into varyMap
floatToTagExpr :: (Autofloat a) => a -> TagExpr a
floatToTagExpr n = Done (FloatV n)

-- | converting from Value to TagExpr
toTagExpr :: (Autofloat a) => Value a -> TagExpr a
toTagExpr v = Done v

-- | converting from TagExpr to Value
toVal :: (Autofloat a) => TagExpr a -> Value a
toVal (Done v)    = v
toVal (OptEval _) = error "Shape properties were not fully evaluated"

toFn :: OptType -> StyleOptFn -> Fn
toFn otype (name, args) = Fn {fname = name, fargs = args, optType = otype}

toFns :: ([StyleOptFn], [StyleOptFn]) -> ([Fn], [Fn])
toFns (objfns, constrfns) =
  (map (toFn Objfn) objfns, map (toFn Constrfn) constrfns)

list2 (a, b) = [a, b]

mkVaryMap :: (Autofloat a) => [Path] -> [a] -> VaryMap a
mkVaryMap varyPaths varyVals =
  M.fromList $ zip varyPaths (map floatToTagExpr varyVals)

------------------- Translation helper functions
------ Generic functions for folding over a translation
foldFields ::
     (Autofloat a)
  => (String -> Field -> FieldExpr a -> [b] -> [b])
  -> Name
  -> FieldDict a
  -> [b]
  -> [b]
foldFields f name fieldDict acc =
  let res = M.foldrWithKey (f name) [] fieldDict
  in res ++ acc

foldSubObjs ::
     (Autofloat a)
  => (String -> Field -> FieldExpr a -> [b] -> [b])
  -> Translation a
  -> [b]
foldSubObjs f trans = M.foldrWithKey (foldFields f) [] (trMap trans)

------- Inserting into a translation
insertGPI ::
     (Autofloat a)
  => Translation a
  -> String
  -> Field
  -> ShapeTypeStr
  -> PropertyDict a
  -> Translation a
insertGPI trans n field t propDict =
  case M.lookup n $ trMap trans of
    Nothing -> error "Substance ID does not exist"
    Just fieldDict ->
      let fieldDict' = M.insert field (FGPI t propDict) fieldDict
          trMap' = M.insert n fieldDict' $ trMap trans
      in trans {trMap = trMap'}

insertPath ::
     (Autofloat a)
  => Translation a
  -> (Path, TagExpr a)
  -> Either [Error] (Translation a)
insertPath trans (path, expr) =
  let overrideFlag = False -- These paths should not exist in trans
  in addPath overrideFlag trans path expr

insertPaths ::
     (Autofloat a) => [Path] -> [TagExpr a] -> Translation a -> Translation a
insertPaths varyingPaths varying trans =
  if length varying /= length varyingPaths
    then error "not the same # varying paths as varying variables"
    else case foldM insertPath trans (zip varyingPaths varying) of
           Left errs ->
             error $
             "Error while adding varying paths: " ++ intercalate "\n" errs
           Right tr -> tr

------- Looking up fields/properties in a translation
-- First check if the path is a varying path. If so then use the varying value
-- (The value in the translation is stale and should be ignored)
-- If not then use the expr in the translation
lookupFieldWithVarying ::
     (Autofloat a)
  => BindingForm
  -> Field
  -> Translation a
  -> VaryMap a
  -> FieldExpr a
lookupFieldWithVarying bvar field trans varyMap =
  case M.lookup (mkPath [bvarToString bvar, field]) varyMap of
    Just varyVal -> FExpr varyVal
    Nothing      -> lookupField bvar field trans

lookupPropertyWithVarying ::
     (Autofloat a)
  => BindingForm
  -> Field
  -> Property
  -> Translation a
  -> VaryMap a
  -> TagExpr a
lookupPropertyWithVarying bvar field property trans varyMap =
  case M.lookup (mkPath [bvarToString bvar, field, property]) varyMap of
    Just varyVal -> varyVal
    Nothing      -> lookupProperty bvar field property trans

lookupPaths :: (Autofloat a) => [Path] -> Translation a -> [a]
lookupPaths paths trans = map lookupPath paths
  where
    -- Have to look up AccessPaths first, since they make a recursive call, and are not invalid paths themselves 
    lookupPath p@(AccessPath (FieldPath b f) [i]) =
       case lookupField b f trans of
         FExpr (OptEval (Vector es)) -> if es !! i == AFloat (Vary) 
                                        then error ("expected non-?: " ++ show p ++ ", " ++ show es)
                                        else r2f $ floatOf $ es !! i
         FExpr (Done (VectorV es)) -> es !! i
         xs -> error ("varying path \"" ++
             pathStr p ++ "\" is invalid: is '" ++ show xs ++ "'")
    lookupPath p@(AccessPath (PropertyPath b f pr) [i]) =
       case lookupProperty b f pr trans of
         OptEval (Vector es) -> if es !! i == AFloat (Vary) 
                                then error ("expected non-?: " ++ show p ++ ", " ++ show es)
                                else r2f $ floatOf $ es !! i
         Done (VectorV es) -> es !! i
         xs -> error ("varying path \"" ++
             pathStr p ++ "\" is invalid: is '" ++ show xs ++ "'")
    lookupPath p@(FieldPath v field) =
      case lookupField v field trans of
        FExpr (OptEval (AFloat (Fix n))) -> r2f n
        FExpr (Done (FloatV n)) -> r2f n
        xs ->
          error
            ("varying path \"" ++
             pathStr p ++ "\" is invalid: is '" ++ show xs ++ "'")
    lookupPath p@(PropertyPath v field pty) =
      case lookupProperty v field pty trans of
        OptEval (AFloat (Fix n)) -> r2f n
        Done (FloatV n) -> n
        xs ->
          error
            ("varying path \"" ++
             pathStr p ++ "\" is invalid: is '" ++ show xs ++ "'")
    floatOf (AFloat (Fix f)) = f

-- TODO: resolve label logic here?
shapeExprsToVals ::
     (Autofloat a) => (String, Field) -> PropertyDict a -> Properties a
shapeExprsToVals (subName, field) properties =
  let shapeName = getShapeName subName field
      properties' = M.map toVal properties
  in M.insert "name" (StrV shapeName) properties'

getShapes :: (Autofloat a) => [(String, Field)] -> Translation a -> [Shape a]
getShapes shapePaths trans = map (getShape trans) shapePaths
          -- TODO: fix use of Sub/Sty name here
  where
    getShape trans (name, field) =
      let fexpr = lookupField (BSubVar $ VarConst name) field trans
      in case fexpr of
           FExpr _ -> error "expected GPI, got field"
           FGPI ctor properties ->
             (ctor, shapeExprsToVals (name, field) properties)

----- GPI helper functions
shapes2vals :: (Autofloat a) => [Shape a] -> [Path] -> [Value a]
shapes2vals shapes paths = reverse $ foldl' (lookupPath shapes) [] paths
  where
    lookupPath shapes acc (PropertyPath s field property) =
      let subID = bvarToString s
          shapeName = getShapeName subID field
      in get (findShape shapeName shapes) property : acc
    lookupPath _ acc (FieldPath _ _) = acc

-- Given a set of new shapes (from the frontend) and a varyMap (for varying field values):
-- look up property values in the shapes and field values in the varyMap
-- NOTE: varyState is constructed using a foldl, so to preserve its order, we must reverse the list of values!
shapes2floats :: (Autofloat a) => [Shape a] -> VaryMap a -> [Path] -> [a]
shapes2floats shapes varyMap varyingPaths =
  reverse $ foldl' (lookupPathFloat shapes varyMap) [] varyingPaths
  where
    lookupPathFloat ::
         (Autofloat a) => [Shape a] -> VaryMap a -> [a] -> Path -> [a]

    lookupPathFloat shapes varyMap acc p@(AccessPath fp@(FieldPath b f) [i]) =
      case M.lookup p varyMap of
        Just (Done (FloatV num)) -> num : acc
        Just _ ->
          error
            ("wrong type for varying field path (expected float): " ++ show fp)
        Nothing ->
          error
            ("could not find varying field path '" ++ show fp ++ "' in varyMap: " ++ show varyMap)
                    
    lookupPathFloat shapes varyMap acc p@(AccessPath (PropertyPath s field property) [i]) =
      let subID = bvarToString s
          shapeName = getShapeName subID field
          res = getVec (findShape shapeName shapes) property
      in (res !! i) : acc

    lookupPathFloat shapes _ acc (PropertyPath s field property) =
      let subID = bvarToString s
          shapeName = getShapeName subID field
      in getNum (findShape shapeName shapes) property : acc

    lookupPathFloat _ varyMap acc fp@(FieldPath _ _) =
      case M.lookup fp varyMap of
        Just (Done (FloatV num)) -> num : acc
        Just _ ->
          error
            ("wrong type for varying field path (expected float): " ++ show fp)
        Nothing ->
          error
            ("could not find varying field path '" ++ show fp ++ "' in varyMap: " ++ show varyMap)

    floatOf (AFloat (Fix f)) = f


--------------------------------- Analyzing the translation
--- Find varying (float) paths
-- For now, don't optimize these float-valued properties of a GPI
-- (use whatever they are initialized to in Shapes or set to in Style)
unoptimizedFloatProperties :: [String]
unoptimizedFloatProperties =
  [ "rotation"
  , "strokeWidth"
  , "thickness"
  , "transform"
  , "transformation"
  , "opacity"
  , "finalW"
  , "finalH"
  , "arrowheadSize"
  ]

optimizedVectorProperties :: [String]
optimizedVectorProperties =
  [ "start"
  , "end"
  , "center"
  ]

-- Look for nested varying variables, given the path to its parent var (e.g. `x.r` => (-1.2, ?)) => `x.r`[1] is varying
findNestedVarying :: (Autofloat a) => TagExpr a -> Path -> [Path]
findNestedVarying (OptEval (Vector es)) p = map (\(e, i) -> AccessPath p [i]) $ filter (\(e, i) -> isVarying e) $ zip es ([0..] :: [Int])
-- COMBAK: This should search, but for now we just don't handle nested varying vars in these
findNestedVarying (OptEval (Matrix _)) p = []
findNestedVarying (OptEval (List _)) p = []
findNestedVarying (OptEval (Tuple _ _)) p = []
findNestedVarying _ _ = []

-- If any float property is not initialized in properties,
-- or it's in properties and declared varying, it's varying
findPropertyVarying ::
     (Autofloat a)
  => String
  -> Field
  -> M.Map String (TagExpr a)
  -> String
  -> [Path]
  -> [Path]
findPropertyVarying name field properties floatProperty acc =
  case M.lookup floatProperty properties of
    Nothing ->
      if floatProperty `elem` unoptimizedFloatProperties
        then acc
        else if floatProperty `elem` optimizedVectorProperties
        then let paths = findNestedVarying (OptEval $ Vector [AFloat Vary, AFloat Vary]) (mkPath [name, field, floatProperty]) 
             -- Return paths for both elements, COMBAK: This hardcodes that unset vectors have 2 elements, need to generalize
             in paths ++ acc
        else mkPath [name, field, floatProperty] : acc
    Just expr ->
      if declaredVarying expr
        then mkPath [name, field, floatProperty] : acc
        else let paths = findNestedVarying expr (mkPath [name, field, floatProperty]) -- Handles vectors
             in paths ++ acc

findFieldVarying ::
     (Autofloat a) => String -> Field -> FieldExpr a -> [Path] -> [Path]
findFieldVarying name field (FExpr expr) acc =
  if declaredVarying expr
    then mkPath [name, field] : acc -- TODO: deal with StyVars
    else let paths = findNestedVarying expr (mkPath [name, field])
         in paths ++ acc
findFieldVarying name field (FGPI typ properties) acc =
  let ctorFloats = propertiesOf FloatT typ ++ propertiesOf VectorT typ
      varyingFloats = filter (not . isPending typ) ctorFloats
      -- This splits up vector-typed properties into one path for each element
      vs = foldr (findPropertyVarying name field properties) [] varyingFloats
  in vs ++ acc

findVarying :: (Autofloat a) => Translation a -> [Path]
findVarying = foldSubObjs findFieldVarying

--- Find pending paths
-- | Find the paths to all pending, non-float, non-name properties
findPending :: (Autofloat a) => Translation a -> [Path]
findPending = foldSubObjs findFieldPending
  where
    pendingProp _ (Pending _) = True
    pendingProp _ _           = False
    findFieldPending name field (FExpr expr) acc = acc
    findFieldPending name field (FGPI typ properties) acc =
      let pendingProps = M.keys $ M.filterWithKey pendingProp properties
      in map (\p -> mkPath [name, field, p]) pendingProps ++ acc

--- Find uninitialized (non-float) paths
findPropertyUninitialized ::
     (Autofloat a)
  => String
  -> Field
  -> M.Map String (TagExpr a)
  -> String
  -> [Path]
  -> [Path]
findPropertyUninitialized name field properties nonfloatProperty acc =
  case M.lookup nonfloatProperty properties
    -- nonfloatProperty is a non-float property that is NOT set by the user and thus we can sample it
        of
    Nothing   -> mkPath [name, field, nonfloatProperty] : acc
    Just expr -> acc

findFieldUninitialized ::
     (Autofloat a) => String -> Field -> FieldExpr a -> [Path] -> [Path]
-- NOTE: we don't find uninitialized field because you can't leave them uninitialized. Plus, we don't know what types they are
findFieldUninitialized name field (FExpr expr) acc = acc
findFieldUninitialized name field (FGPI typ properties) acc =
  let ctorNonfloats = filter (/= "name") $ propertiesNotOf FloatT typ
  in let uninitializedProps = ctorNonfloats
     in let vs =
              foldr
                (findPropertyUninitialized name field properties)
                []
                uninitializedProps
        in vs ++ acc

-- | Find the paths to all uninitialized, non-float, non-name properties
findUninitialized :: (Autofloat a) => Translation a -> [Path]
findUninitialized = foldSubObjs findFieldUninitialized

--- Find various kinds of functions
findObjfnsConstrs ::
     (Autofloat a) => Translation a -> [Either StyleOptFn StyleOptFn]
findObjfnsConstrs = foldSubObjs findFieldFns
  where
    findFieldFns ::
         (Autofloat a)
      => String
      -> Field
      -> FieldExpr a
      -> [Either StyleOptFn StyleOptFn]
      -> [Either StyleOptFn StyleOptFn]
    findFieldFns name field (FExpr (OptEval expr)) acc =
      case expr of
        ObjFn fname args    -> Left (fname, args) : acc
        ConstrFn fname args -> Right (fname, args) : acc
        _                   -> acc -- Not an optfn
          -- COMBAK: what should we do if there's a constant field?
    findFieldFns name field (FExpr (Done _)) acc = acc
    findFieldFns name field (FGPI _ _) acc = acc

findDefaultFns ::
     (Autofloat a) => Translation a -> [Either StyleOptFn StyleOptFn]
findDefaultFns = foldSubObjs findFieldDefaultFns
  where
    findFieldDefaultFns ::
         (Autofloat a)
      => String
      -> Field
      -> FieldExpr a
      -> [Either StyleOptFn StyleOptFn]
      -> [Either StyleOptFn StyleOptFn]
    findFieldDefaultFns name field gpi@(FGPI typ props) acc =
      let args = [EPath $ FieldPath (BSubVar (VarConst name)) field]
          objs = map (Left . addArgs args) $ defaultObjFnsOf typ
          constrs = map (Right . addArgs args) $ defaultConstrsOf typ
      in constrs ++ objs ++ acc
      where
        addArgs arguments f = (f, arguments)
    findFieldDefaultFns _ _ _ acc = acc

--- Find shapes and their properties
findShapeNames :: (Autofloat a) => Translation a -> [(String, Field)]
findShapeNames = foldSubObjs findGPIName
  where
    findGPIName ::
         (Autofloat a)
      => String
      -> Field
      -> FieldExpr a
      -> [(String, Field)]
      -> [(String, Field)]
    findGPIName name field (FGPI _ _) acc = (name, field) : acc
    findGPIName _ _ (FExpr _) acc         = acc

findShapesProperties ::
     (Autofloat a) => Translation a -> [(String, Field, Property)]
findShapesProperties = foldSubObjs findShapeProperties
  where
    findShapeProperties ::
         (Autofloat a)
      => String
      -> Field
      -> FieldExpr a
      -> [(String, Field, Property)]
      -> [(String, Field, Property)]
    findShapeProperties name field (FGPI ctor properties) acc =
      let paths = map (\property -> (name, field, property)) (M.keys properties)
      in paths ++ acc
    findShapeProperties _ _ (FExpr _) acc = acc

------------------------------ Evaluating the translation and expressions/GPIs in it
-- TODO: write a more general typechecking mechanism
evalUop :: (Autofloat a) => UnaryOp -> ArgVal a -> Value a
evalUop UMinus v =
  case v of
    Val (FloatV a) -> FloatV (-a)
    Val (IntV i)   -> IntV (-i)
    GPI _          -> error "cannot negate a GPI"
    Val _          -> error "wrong type to negate"
evalUop UPlus v = error "unary + doesn't make sense" -- TODO remove from parser

evalBinop :: (Autofloat a) => BinaryOp -> ArgVal a -> ArgVal a -> Value a
evalBinop op v1 v2 =
  case (v1, v2) of
    (Val (FloatV n1), Val (FloatV n2)) ->
      case op of
        BPlus -> FloatV $ n1 + n2
        BMinus -> FloatV $ n1 - n2
        Multiply -> FloatV $ n1 * n2
        Divide ->
          if n2 == 0
            then error "divide by 0!"
            else FloatV $ n1 / n2
        Exp -> FloatV $ n1 ** n2
    (Val (IntV n1), Val (IntV n2)) ->
      case op of
        BPlus -> IntV $ n1 + n2
        BMinus -> IntV $ n1 - n2
        Multiply -> IntV $ n1 * n2
        Divide ->
          if n2 == 0
            then error "divide by 0!"
            else IntV $ n1 `quot` n2 -- NOTE: not float
        Exp -> IntV $ n1 ^ n2
        -- Cannot mix int and float
    (Val _, Val _) ->
      error
        ("wrong field types for binary op: " ++ show v1 ++ show op ++ show v2)
    (GPI _, Val _) -> error "binop cannot operate on GPI"
    (Val _, GPI _) -> error "binop cannot operate on GPI"
    (GPI _, GPI _) -> error "binop cannot operate on GPIs"

-- | Given a path that is a computed property of a shape (e.g. A.shape.transformation), evaluate each of its arguments (e.g. A.shape.sizeX), pass the results to the property-computing function, and return the result (e.g. an HMatrix)
computeProperty ::
     (Autofloat a)
  => (Int, Int)
  -> BindingForm
  -> Field
  -> Property
  -> VaryMap a
  -> Translation a
  -> StdGen
  -> ComputedValue a
  -> (ArgVal a, Translation a, StdGen)
computeProperty limit bvar field property varyMap trans g (props, compFn) =
  let args = map (\p -> EPath $ PropertyPath bvar field p) props
      (argVals, trans', g') = evalExprs limit args trans varyMap g
      propertyValue = compFn $ map fromGPI argVals
  in (Val propertyValue, trans', g')
  where
    fromGPI (Val x) = x
    fromGPI (GPI x) = error "expected value as prop fn arg, got GPI"

evalProperty ::
     (Autofloat a)
  => (Int, Int)
  -> BindingForm
  -> Field
  -> VaryMap a
  -> ([(Property, TagExpr a)], Translation a, StdGen)
  -> (Property, TagExpr a)
  -> ([(Property, TagExpr a)], Translation a, StdGen)
evalProperty (i, n) bvar field varyMap (propertiesList, trans, g) (property, expr) =
  let path = EPath $ PropertyPath bvar field property -- factor out?
  in let (res, trans', g') = evalExpr (i, n) path trans varyMap g
    -- This check might be redundant with the later GPI conversion in evalExpr, TODO factor out
     in case res of
          Val val -> ((property, Done val) : propertiesList, trans', g')
          GPI _   -> error "GPI property should not evaluate to GPI argument" -- TODO: true later? references?

evalGPI_withUpdate ::
     (Autofloat a)
  => (Int, Int)
  -> BindingForm
  -> Field
  -> (GPICtor, PropertyDict a)
  -> Translation a
  -> VaryMap a
  -> StdGen
  -> ((GPICtor, PropertyDict a), Translation a, StdGen)
evalGPI_withUpdate (i, n) bvar field (ctor, properties) trans varyMap g
        -- Fold over the properties, evaluating each path, which will update the translation each time,
        -- and accumulate the new property-value list (WITH varying looked up)
 =
  let (propertyList', trans', g') =
        foldl'
          (evalProperty (i, n) bvar field varyMap)
          ([], trans, g)
          (M.toList properties)
  in let properties' = M.fromList propertyList'
        {-trace ("Start eval GPI: " ++ show properties ++ " " ++ "\n\tctor: " ++ "\n\tfield: " ++ show field)-}
     in ((ctor, properties'), trans', g')

-- recursively evaluate, tracking iteration depth in case there are cycles in graph
evalExpr ::
     (Autofloat a)
  => (Int, Int)
  -> Expr
  -> Translation a
  -> VaryMap a
  -> StdGen
  -> (ArgVal a, Translation a, StdGen)
evalExpr (i, n) arg trans varyMap g =
  if i >= n
    then error ("evalExpr: iteration depth exceeded (" ++ show n ++ ")")
    else argResult {-trace ("Evaluating expression: " ++ show arg ++ "\n(i, n): " ++ show i ++ ", " ++ show n)-}
  where
    limit = (i + 1, n)
    argResult =
      case arg
            -- Already done values; don't change trans
            of
        IntLit i -> (Val $ IntV i, trans, g)
        StringLit s -> (Val $ StrV s, trans, g)
        BoolLit b -> (Val $ BoolV b, trans, g)
        AFloat (Fix f) -> (Val $ FloatV (r2f f), trans, g) -- TODO: note use of r2f here. is that ok?
        AFloat Vary ->
          error "evalExpr should not encounter an uninitialized varying float!"
            -- Inline computation, needs a recursive lookup that may change trans, but not a path
            -- TODO factor out eval / trans computation?
        UOp op e ->
          let (val, trans', g') = evalExpr limit e trans varyMap g
          in let compVal = evalUop op val
             in (Val compVal, trans', g')
        BinOp op e1 e2 ->
          let ([v1, v2], trans', g') = evalExprs limit [e1, e2] trans varyMap g
          in let compVal = evalBinop op v1 v2
             in (Val compVal, trans', g')
        CompApp fname args
                -- NOTE: the goal of all the rng passing in this module is for invoking computations with randomization
         ->
          let (vs, trans', g') = evalExprs limit args trans varyMap g
              (compRes, g'') = invokeComp fname vs compSignatures g'
          in (compRes, trans', g'')
                -- -- TODO: invokeComp should be used here
                -- case M.lookup fname compDict of
                -- Nothing -> error ("computation '" ++ fname ++ "' doesn't exist")
                -- Just f -> let res = f vs in
                --           (res, trans')
        List es ->
          let (vs, trans', g') = evalExprs limit es trans varyMap g
              floatvs = map checkListElemType vs
          in (Val $ ListV floatvs, trans', g')
        ListAccess p i -> error "TODO list accesses"
        Tuple e1 e2 ->
          let (vs, trans', g') = evalExprs limit [e1, e2] trans varyMap g
              [v1, v2] = map checkListElemType vs
          in (Val $ TupV (v1, v2), trans', g')
            -- Needs a recursive lookup that may change trans. The path case is where trans is actually changed.
        EPath p ->
          case p of
            FieldPath bvar field
                     -- Lookup field expr, evaluate it if necessary, cache the evaluated value in the trans,
                     -- return the evaluated value and the updated trans
             ->
              let fexpr = lookupFieldWithVarying bvar field trans varyMap
              in case fexpr of
                   FExpr (Done v) -> (Val v, trans, g)
                   FExpr (OptEval e) ->
                     let (v, trans', g') = evalExpr limit e trans varyMap g
                     in case v of
                          Val fval ->
                            case insertPath trans' (p, Done fval) of
                              Right trans' -> (v, trans', g')
                              Left err     -> error $ concat err
                          gpiVal@(GPI _) -> (gpiVal, trans', g') -- to deal with path synonyms, e.g. "y.f = some GPI; z.f = y.f"
                   FGPI ctor properties
                     -- Eval each property in the GPI, storing each property result in a new dictionary
                     -- No need to update the translation because each path should update the translation
                    ->
                     let (gpiVal@(ctor', propertiesVal), trans', g') =
                           evalGPI_withUpdate
                             limit
                             bvar
                             field
                             (ctor, properties)
                             trans
                             varyMap
                             g
                     in ( GPI
                            ( ctor'
                            , shapeExprsToVals
                                (bvarToString bvar, field)
                                propertiesVal)
                        , trans'
                        , g')
            PropertyPath bvar field property ->
              let gpiType = shapeType bvar field trans
              in case M.lookup (gpiType, property) computedProperties of
                   Just computeValueInfo ->
                     computeProperty
                       limit
                       bvar
                       field
                       property
                       varyMap
                       trans
                       g
                       computeValueInfo
                   Nothing -- Compute the path as usual
                    ->
                     let texpr =
                           lookupPropertyWithVarying
                             bvar
                             field
                             property
                             trans
                             varyMap
                     in case texpr of
                          Pending v -> (Val v, trans, g)
                          Done v -> (Val v, trans, g)
                          OptEval e ->
                            let (v, trans', g') =
                                  evalExpr limit e trans varyMap g
                            in case v of
                                 Val fval ->
                                   case insertPath trans' (p, Done fval) of
                                     Right trans' -> (v, trans', g')
                                     Left err     -> error $ concat err
                                 GPI _ ->
                                   error
                                     ("path to property expr '" ++
                                      pathStr p ++ "' evaluated to a GPI")
            -- GPI argument
        Ctor ctor properties ->
          error "no anonymous/inline GPIs allowed as expressions!"
            -- Error
        Layering _ _ ->
          error
            "layering should not be an objfn arg (or in the children of one)"
        ObjFn _ _ ->
          error "objfn should not be an objfn arg (or in the children of one)"
        ConstrFn _ _ ->
          error
            "constrfn should not be an objfn arg (or in the children of one)"
        AvoidFn _ _ ->
          error "avoidfn should not be an objfn arg (or in the children of one)"
        PluginAccess _ _ _ ->
          error "plugin access should not be evaluated at runtime"
        xs -> error ("unmatched case in evalExpr with argument: " ++ show xs)

checkListElemType :: (Autofloat a) => ArgVal a -> a
checkListElemType (Val (FloatV x)) = x
checkListElemType _                = error "expected float type"

-- Any evaluated exprs are cached in the translation for future evaluation
-- The varyMap is not changed because its values are final (set by the optimization)
evalExprs ::
     (Autofloat a)
  => (Int, Int)
  -> [Expr]
  -> Translation a
  -> VaryMap a
  -> StdGen
  -> ([ArgVal a], Translation a, StdGen)
evalExprs limit args trans varyMap g =
  foldl' (evalExprF limit varyMap) ([], trans, g) args
  where
    evalExprF ::
         (Autofloat a)
      => (Int, Int)
      -> VaryMap a
      -> ([ArgVal a], Translation a, StdGen)
      -> Expr
      -> ([ArgVal a], Translation a, StdGen)
    evalExprF limit varyMap (argvals, trans, rng) arg =
      let (argVal, trans', rng') = evalExpr limit arg trans varyMap rng
      in (argvals ++ [argVal], trans', rng') -- So returned exprs are in same order

------------- Evaluating all shapes in a translation
evalShape ::
     (Autofloat a)
  => (Int, Int)
  -> VaryMap a
  -> ([Shape a], Translation a, StdGen)
  -> Path
  -> ([Shape a], Translation a, StdGen)
evalShape limit varyMap (shapes, trans, g) shapePath =
  let (res, trans', g') = evalExpr limit (EPath shapePath) trans varyMap g
  in case res of
       GPI shape -> (shape : shapes, trans', g')
       _         -> error "evaluating a GPI path did not result in a GPI"

-- recursively evaluate every shape property in the translation
evalShapes ::
     (Autofloat a)
  => (Int, Int)
  -> [Path]
  -> Translation a
  -> VaryMap a
  -> StdGen
  -> ([Shape a], Translation a, StdGen)
evalShapes limit shapePaths trans varyMap rng =
  let (shapes, trans', rng') =
        foldl' (evalShape limit varyMap) ([], trans, rng) shapePaths
  in (reverse shapes, trans', rng')

-- Given the shape names, use the translation and the varying paths/values in order to evaluate each shape
-- with respect to the varying values
evalTranslation :: State -> ([Shape Double], Translation Double, StdGen)
evalTranslation s =
  let varyMap = mkVaryMap (varyingPaths s) (map r2f $ varyingState s)
  in evalShapes evalIterRange (shapePaths s) (transr s) varyMap (rng s)

------------- Compute global layering of GPIs
lookupGPIName :: (Autofloat a) => Path -> Translation a -> String
lookupGPIName path@(FieldPath v field) trans =
  case lookupField v field trans of
    FExpr e
           -- to deal with path synonyms in a layering statement (see `lookupProperty` for more explanation)
     ->
      case e of
        OptEval (EPath pathSynonym@(FieldPath vSynonym fieldSynonym)) ->
          if v == vSynonym && field == fieldSynonym
            then error
                   ("nontermination in lookupGPIName w/ path '" ++
                    show path ++ "' set to itself")
            else lookupGPIName pathSynonym trans
        _ -> notGPIError
    FGPI _ _ -> getShapeName (bvarToString v) field
lookupGPIName _ _ = notGPIError

notGPIError = error "Layering expressions can only operate on GPIs."

-- | Walk the translation to find all layering statements.
findLayeringExprs :: (Autofloat a) => Translation a -> [Expr]
findLayeringExprs t = foldSubObjs findLayeringExpr t
  where
    findLayeringExpr ::
         (Autofloat a) => String -> Field -> FieldExpr a -> [Expr] -> [Expr]
    findLayeringExpr name field fexpr acc =
      case fexpr of
        FExpr (OptEval x@(Layering _ _)) -> x : acc
        _                                -> acc

-- | Calculates all the nodes that are part of cycles in a graph.
cyclicNodes :: Graph.Graph -> [Graph.Vertex]
cyclicNodes graph = map fst . filter isCyclicAssoc . assocs $ graph
  where
    isCyclicAssoc = uncurry $ reachableFromAny graph

-- | In the specified graph, can the specified node be reached, starting out
-- from any of the specified vertices?
reachableFromAny :: Graph.Graph -> Graph.Vertex -> [Graph.Vertex] -> Bool
reachableFromAny graph node = elem node . concatMap (Graph.reachable graph)

-- | 'topSortLayering' takes in a list of all GPI names and a list of directed edges [(a -> b)] representing partial layering orders as input and outputs a linear layering order of GPIs
topSortLayering :: [String] -> [(String, String)] -> Maybe [String]
topSortLayering names partialOrderings =
  let orderedNodes = nodesFromEdges partialOrderings
      freeNodes = Set.difference (Set.fromList names) orderedNodes
      edges =
        map (\(x, y) -> (x, x, y)) $
        adjList partialOrderings ++ (map (\x -> (x, [])) $ Set.toList freeNodes)
      (graph, nodeFromVertex, vertexFromKey) = Graph.graphFromEdges edges
      cyclic = not . null $ cyclicNodes graph
  in if cyclic
       then Nothing
       else Just $ map (getNodePart . nodeFromVertex) $ Graph.topSort graph
  where
    getNodePart (n, _, _) = n

nodesFromEdges edges = Set.fromList $ concatMap (\(a, b) -> [a, b]) edges

adjList :: [(String, String)] -> [(String, [String])]
adjList edges =
  let nodes = Set.toList $ nodesFromEdges edges
  in map (\x -> (x, findNeighbors x)) nodes
  where
    findNeighbors node = map snd $ filter ((==) node . fst) edges

computeLayering :: (Autofloat a) => Translation a -> Maybe [String]
computeLayering trans =
  let layeringExprs = findLayeringExprs trans
      partialOrderings = map findNames layeringExprs
      gpiNames = map (uncurry getShapeName) $ findShapeNames trans
  in topSortLayering gpiNames partialOrderings
  where
    unused = -1
    substitute res (block, substs) =
      let block' = (block, unused)
          substs' = map (\s -> (s, unused)) substs
      in res ++ map (`substituteBlock` block') substs'
    findNames (Layering path1 path2) =
      (lookupGPIName path1 trans, lookupGPIName path2 trans)

------------------- Generating and evaluating the objective function
evalFnArgs ::
     (Autofloat a)
  => (Int, Int)
  -> VaryMap a
  -> ([FnDone a], Translation a, StdGen)
  -> Fn
  -> ([FnDone a], Translation a, StdGen)
evalFnArgs limit varyMap (fnDones, trans, g) fn =
  let args = fargs fn
  in let (argsVal, trans', g') = evalExprs limit (fargs fn) trans varyMap g
     in let fn' =
              FnDone
              {fname_d = fname fn, fargs_d = argsVal, optType_d = optType fn}
        in (fnDones ++ [fn'], trans', g') -- TODO factor out this pattern

evalFns ::
     (Autofloat a)
  => (Int, Int)
  -> [Fn]
  -> Translation a
  -> VaryMap a
  -> StdGen
  -> ([FnDone a], Translation a, StdGen)
evalFns limit fns trans varyMap g =
  foldl' (evalFnArgs limit varyMap) ([], trans, g) fns

applyOptFn ::
     (Autofloat a) => M.Map String (OptFn a) -> OptSignatures -> FnDone a -> a
applyOptFn dict sigs finfo =
  let (name, args) = (fname_d finfo, fargs_d finfo)
  in invokeOptFn dict name args sigs

applyCombined :: (Autofloat a) => a -> [FnDone a] -> a
applyCombined penaltyWeight fns
        -- TODO: pass the functions in separately? The combining + separating seem redundant
 =
  let (objfns, constrfns) = partition (\f -> optType_d f == Objfn) fns
  in sumMap (applyOptFn objFuncDict objSignatures) objfns +
     constrWeight * penaltyWeight *
     sumMap (applyOptFn constrFuncDict constrSignatures) constrfns

-- Main function: generates the objective function, partially applying it with some info
genObjfn ::
     (Autofloat a)
  => Translation a
  -> [Fn]
  -> [Fn]
  -> [Path]
  -> StdGen
  -> a
  -> [a]
  -> a
genObjfn trans objfns constrfns varyingPaths =
  \rng penaltyWeight varyingVals ->
    let varyMap = tr "varyingMap: " $ mkVaryMap varyingPaths varyingVals
    in let (fnsE, transE, rng') =
             evalFns evalIterRange (objfns ++ constrfns) trans varyMap rng
       in applyCombined penaltyWeight fnsE

evalEnergyOn :: (Autofloat a) => State -> [a] -> a
evalEnergyOn s vstate =
  let varyMap = mkVaryMap (varyingPaths s) vstate
      fns = objFns s ++ constrFns s
      (fnsE, transE, rng') =
        evalFns evalIterRange fns (castTranslation $ transr s) varyMap (rng s)
      penaltyWeight = r2f $ weight $ paramsr s
  in applyCombined penaltyWeight fnsE

-- TODO: `evalEnergy` is not used anywhere but is meant to be an API call exposed to our future benchmarking frontend.
evalEnergy :: (Autofloat a) => State -> a
evalEnergy s =
  let varyMap = mkVaryMap (varyingPaths s) (map r2f $ varyingState s)
      fns = objFns s ++ constrFns s
      (fnsE, transE, rng') =
        evalFns evalIterRange fns (castTranslation $ transr s) varyMap (rng s)
      penaltyWeight = r2f $ weight $ paramsr s
  in applyCombined penaltyWeight fnsE

--------------- Generating an initial state (concrete values for all fields/properties needed to draw the GPIs)
-- 1. Initialize all varying fields
-- 2. Initialize all properties of all GPIs
-- NOTE: since we store all varying paths separately, it is okay to mark the default values as Done -- they will still be optimized, if needed.
-- TODO: document the logic here (e.g. only sampling varying floats) and think about whether to use translation here or [Shape a] since we will expose the sampler to users later
initProperty ::
     (Autofloat a)
  => ShapeTypeStr
  -> (PropertyDict a, StdGen)
  -> String
  -> (ValueType, SampledValue a)
  -> (PropertyDict a, StdGen)
initProperty shapeType (properties, g) pID (typ, sampleF) =
  let (v, g') = sampleF g
      autoRndVal = Done v
  in case M.lookup pID properties of
       Just (OptEval (AFloat Vary)) -> (M.insert pID autoRndVal properties, g')
       -- TODO: This hardcodes an uninitialized 2D vector to be initialized/inserted
       Just (OptEval (Vector [AFloat Vary, AFloat Vary])) -> (M.insert pID autoRndVal properties, g')
       Just (OptEval e) -> (properties, g)
       Just (Done v) -> (properties, g)
       -- TODO: pending properties are only marked if the Style source does not set them explicitly
       -- Check if this is the right decision. We still give pending values a default such that the initial list of shapes can be generated without errors.
       Nothing ->
         if isPending shapeType pID
           then (M.insert pID (Pending v) properties, g')
           else (M.insert pID autoRndVal properties, g')
       _ -> error ("not handled: " ++ pID ++ ", " ++ show (M.lookup pID properties))

initShape ::
     (Autofloat a)
  => (Translation a, StdGen)
  -> (String, Field)
  -> (Translation a, StdGen)
initShape (trans, g) (n, field) =
  case lookupField (BSubVar (VarConst n)) field trans of
    FGPI shapeType propDict ->
      let def = findDef shapeType
          (propDict', g') =
            foldlPropertyMappings (initProperty shapeType) (propDict, g) def
                -- NOTE: getShapes resolves the names + we don't use the names of the shapes in the translation
                -- The name-adding logic can be removed but is left in for debugging
          shapeName = getShapeName n field
          propDict'' = M.insert "name" (Done $ StrV shapeName) propDict'
      in (insertGPI trans n field shapeType propDict'', g')
    _ -> error "expected GPI but got field"

initShapes ::
     (Autofloat a)
  => Translation a
  -> [(String, Field)]
  -> StdGen
  -> (Translation a, StdGen)
initShapes trans shapePaths gen = foldl' initShape (trans, gen) shapePaths

resampleFields :: (Autofloat a) => [Path] -> StdGen -> ([a], StdGen)
resampleFields varyingPaths g =
  let varyingFields = filter isFieldOrAccessPath varyingPaths
  in randomsIn g (fromIntegral $ length varyingFields) canvasDims

-- sample varying fields only (from the range defined by canvas dims) and store them in the translation
-- example: A.val = OPTIMIZED
-- This also samples varying access paths, e.g.
-- Circle { center : (1.1, ?) ... } <-- the latter is an access path that gets initialized here
initFields ::
     (Autofloat a)
  => [Path]
  -> Translation a
  -> StdGen
  -> (Translation a, StdGen)
initFields varyingPaths trans g =
  let varyingFields = filter isFieldOrAccessPath varyingPaths
      (sampledVals, g') =
        randomsIn g (fromIntegral $ length varyingFields) canvasDims
      trans' = insertPaths varyingFields (map (Done . FloatV) sampledVals) trans
  in (trans', g')

------------- Main function: what the Style compiler generates
genOptProblemAndState :: Translation Double -> OptConfig -> State
genOptProblemAndState trans optConfig
    -- Save information about the translation
 =
  let varyingPaths = findVarying trans
    -- NOTE: the properties in uninitializedPaths are NOT floats. Floats are included in varyingPaths already
      uninitializedPaths = findUninitialized trans
      shapePathList = findShapeNames trans
      shapePaths = map (mkPath . list2) shapePathList
    -- sample varying fields
      (transInitFields, g') = initFields varyingPaths trans initRng
    -- sample varying vals and instantiate all the non-float base properties of every GPI in the translation
      (transInit, g'') = initShapes transInitFields shapePathList g'
      shapeProperties = findShapesProperties transInit
      (objfns, constrfns) =
        (toFns . partitionEithers . findObjfnsConstrs) transInit
      (defaultObjFns, defaultConstrs) =
        (toFns . partitionEithers . findDefaultFns) transInit
      (objFnsWithDefaults, constrsWithDefaults) =
        (objfns ++ defaultObjFns, constrfns ++ defaultConstrs)
    -- Evaluate all expressions once to get the initial shapes
      initVaryingMap = M.empty -- No optimization has happened. Sampled varying vals are in transInit
      (initialGPIs, transEvaled, _) = ([], transInit, g'')
      -- NOTE: Temp hack for web-runtime function names (see issue #352), don't evaluate shapes in backend but in frontend. This will avoid evaluating the translation, so the system won't look for function names here
        -- Previously: `evalShapes evalIterRange shapePaths transInit initVaryingMap g''`
   -- NOTE: intentially discarding the new random feed, since we want the computation result to be consistent within one optimization session
      initState = lookupPaths varyingPaths transEvaled
    -- This is the final Style compiler output
  in State
     { shapesr = initialGPIs
     , shapePaths = shapePaths
     , shapeProperties = shapeProperties
     , shapeOrdering = [] -- NOTE: to be populated later
     , transr = transInit -- note: NOT transEvaled
     , varyingPaths = varyingPaths
     , uninitializedPaths = uninitializedPaths
     , pendingPaths = findPending transInit
     , varyingState = initState
     , objFns = objFnsWithDefaults
     , constrFns = constrsWithDefaults
     , paramsr =
         Params
         { weight = initWeight
         , optStatus = NewIter
         , bfgsInfo = defaultBfgsParams
         }
     , rng = g''
     , policyParams = initPolicyParams
                                --  policyFn = policyToUse,
     , oConfig = optConfig
     , selectorMatches = [] -- to be filled in by caller (compileStyle)
     }
    -- initPolicy  -- TODO: rewrite to avoid the use of lambda functions

-- | 'compileStyle' runs the main Style compiler on the AST of Style and output from the Substance compiler and outputs the initial state for the optimization problem. This function is a top-level function used by "Server" and "ShadowMain"
-- TODO: enable logger
compileStyle ::
     HeaderBlocks
  -> C.SubOut
  -> [J.StyVal]
  -> OptConfig
  -> Either CompilerError State
compileStyle styProgInit (C.SubOut subProg (subEnv, eqEnv) labelMap) styVals optConfig = do
  let selEnvs = checkSels subEnv styProgInit
  let subss = find_substs_prog subEnv eqEnv subProg styProgInit selEnvs
    -- Preprocess Style program to turn anonymous assignments into named ones
  let styProg = nameAnonStatements styProgInit
    -- NOT :: forall a . (Autofloat a) => Either [Error] (Translation a)
    -- We intentionally specialize/monomorphize the translation to Float so it can be fully evaluated
    -- and is not trapped under the lambda of the typeclass (Autofloat a) => ...
    -- This greatly improves the performance of the system. See #166 for more details.
  let trans =
        translateStyProg subEnv eqEnv subProg styProg labelMap styVals :: Either [Error] (Translation Double)
  case trans of
    Left errs -> Left $ StyleTypecheck errs
    Right transAuto -> do
      let initState = genOptProblemAndState transAuto optConfig
      case computeLayering transAuto of
        Just gpiOrdering ->
          Right $
          initState
          {selectorMatches = map length subss, shapeOrdering = gpiOrdering}
        Nothing ->
          Left $
          StyleLayering
            "The graph formed by partial ordering of GPIs is cyclic and therefore can't be sorted."
 -- putStrLn "Parsed Style program\n"
   -- pPrint styProgInit
   -- divLine
   -- Preprocess Style program to turn anonymous assignments into named ones
   -- putStrLn "Named Style program\n"
   -- pPrint styProg
   -- divLine

--    let styProg = nameAnonStatements styProgInit
--    putStrLn "Running Style semantics\n"
--    let selEnvs = checkSels subEnv styProg
--    putStrLn "Selector static semantics and local envs:\n"
--    forM_ selEnvs pPrint
--    divLine
--    let subss = find_substs_prog subEnv eqEnv subProg styProg selEnvs
--    putStrLn "Selector matches:\n"
--    forM_ subss pPrint
--    divLine
--    let subss = find_substs_prog subEnv eqEnv subProg styProg selEnvs
--    putStrLn "(Selector * matches for that selector):\n"
--    forM_ (zip selEnvs subss) pPrint
--    divLine
--    putStrLn "Translated Style program:\n"
--    pPrint trans
--    divLine
--    let initState = genOptProblemAndState transAuto optConfig
--    putStrLn "Generated initial state:\n"
--    print initState
--    divLine
--    -- global layering order computation
--    let gpiOrdering = computeLayering transAuto
--    putStrLn "Generated GPI global layering:\n"
--    print gpiOrdering
--    divLine
-- | After monomorphizing the translation's type (to make sure it's computed), we generalize the type again, which means
-- | it's again under a typeclass lambda. (#166)
castTranslation ::
     Translation Double
  -> (forall a. Autofloat a =>
                  Translation a)
castTranslation t =
  let res = M.map castFieldDict (trMap t)
  in t {trMap = res}
  where
    castFieldDict ::
         FieldDict Double
      -> (forall a. Autofloat a =>
                      FieldDict a)
    castFieldDict dict = M.map castFieldExpr dict
    castFieldExpr ::
         FieldExpr Double
      -> (forall a. (Autofloat a) =>
                      FieldExpr a)
    castFieldExpr e =
      case e of
        FExpr te     -> FExpr $ castTagExpr te
        FGPI n props -> FGPI n $ M.map castTagExpr props
    castTagExpr ::
         TagExpr Double
      -> (forall a. Autofloat a =>
                      TagExpr a)
    castTagExpr e =
      case e of
        Done v    -> Done $ castValue v
        Pending v -> Pending $ castValue v
        OptEval e -> OptEval e -- Expr only contains floats
    castValue ::
         Value Double
      -> (forall a. Autofloat a =>
                      Value a)
    castValue v =
      let castPtList = map (app2 r2f)
          castPolys = map castPtList
          res =
            case v of
              FloatV x -> FloatV (r2f x)
              PtV (x, y) -> PtV (r2f x, r2f y)
              PtListV pts -> PtListV $ castPtList pts
              VectorV xs -> VectorV $ map r2f xs
              MatrixV xs -> MatrixV $ map (map r2f) xs
              TupV x -> TupV $ r2 x
              LListV xs -> LListV $ map (map r2f) xs
              PathDataV d -> PathDataV $ map castPath d
                          -- More boilerplate not involving floats
              IntV x -> IntV x
              BoolV x -> BoolV x
              StrV x -> StrV x
              FileV x -> FileV x
              StyleV x -> StyleV x
              ColorV (RGBA r g b a) ->
                ColorV $ RGBA (r2f r) (r2f g) (r2f b) (r2f a)
              PolygonV (pos, neg, (p1, p2), samples) ->
                PolygonV
                  ( castPolys pos
                  , castPolys neg
                  , (app2 r2f p1, app2 r2f p2)
                  , castPtList samples)
      in res
      where r2 (x, y) = (r2f x, r2f y)
    castPath ::
         SubPath Double
      -> (forall a. Autofloat a =>
                      SubPath a)
    castPath p =
      case p of
        Closed elems -> Closed $ map castElem elems
        Open elems   -> Open $ map castElem elems
    castElem ::
         Elem Double
      -> (forall a. Autofloat a =>
                      Elem a)
    castElem e =
      case e of
        Pt pt            -> Pt $ app2 r2f pt
        CubicBez pts     -> CubicBez $ app3 (app2 r2f) pts
        CubicBezJoin pts -> CubicBezJoin $ app2 (app2 r2f) pts
        QuadBez pts      -> QuadBez $ app2 (app2 r2f) pts
        QuadBezJoin pt   -> QuadBezJoin $ app2 r2f pt

-------------------------------
-- Sampling code
-- TODO: should this code go in the optimizer?
numStateSamples :: Int
numStateSamples = 500

-- | Resample the varying state.
-- | We are intentionally using a monomorphic type (float) and NOT using the translation, to avoid slowness.
resampleVState ::
     [Path]
  -> [Shape Double]
  -> StdGen
  -> (([Shape Double], [Double], [Double]), StdGen)
resampleVState varyPaths shapes g =
  let (resampledShapes, rng') = sampleShapes g shapes
      (resampledFields, rng'') = resampleFields varyPaths rng'
        -- make varying map using the newly sampled fields (we do not need to insert the shape paths)
      varyMapNew = mkVaryMap (filter isFieldOrAccessPath varyPaths) resampledFields
      varyingState = shapes2floats resampledShapes varyMapNew varyPaths
  in ((resampledShapes, varyingState, resampledFields), rng'')

-- | Update the translation to get the full state.
updateVState :: State -> (([Shape Double], [Double], [Double]), StdGen) -> State
updateVState s ((resampledShapes, varyingState', fields'), g) =
  let polyShapes = toPolymorphics resampledShapes
      uninitVals = map toTagExpr $ shapes2vals polyShapes $ uninitializedPaths s
      trans' = insertPaths (uninitializedPaths s) uninitVals (transr s)
                    -- TODO: shapes', rng' = sampleConstrainedState (rng s) (shapesr s) (constrs s)
      varyMapNew = mkVaryMap (filter isFieldOrAccessPath $ varyingPaths s) fields'
        -- TODO: this is not necessary for now since the label dimensions do not change, but added for completeness
      pendingPaths = findPending trans'
  in s
     { shapesr = polyShapes
     , rng = g
     , transr = trans' {warnings = []} -- Clear the warnings, since they aren't relevant anymore
     , varyingState = map r2f varyingState'
     , pendingPaths = pendingPaths
     , paramsr = (paramsr s) {weight = initWeight, optStatus = NewIter}
     }
    -- NOTE: for now we do not update the new state with the new rng from eval.
    -- The results still look different because resampling updated the rng.
    -- Therefore, we do not have to update rng here.

-- | Iterate a function that uses a generator, generating an infinite list of results with their corresponding updated generators.
iterateS :: (a -> (b, a)) -> a -> [(b, a)]
iterateS f g =
  let (res, g') = f g
  in (res, g') : iterateS f g'

-- | Compare two states and return the one with less energy.
lessEnergyOn ::
     ([Double] -> Double)
  -> (([Shape Double], [Double], [Double]), StdGen)
  -> (([Shape Double], [Double], [Double]), StdGen)
  -> Ordering
lessEnergyOn f ((_, vs1, _), _) ((_, vs2, _), _) = compare (f vs1) (f vs2)

-- | Resample the varying state some number of times (sampling each new state from the original state, but with an updated rng).
-- | Pick the one with the lowest energy and update the original state with the lowest-energy-state's info.
-- | NOTE: Assumes that n is greater than 1
resampleBest :: Int -> State -> State
resampleBest n s =
  let optInfo = paramsr s
      -- Take out the relevant information for resampling
      f = evalEnergyOn s
      (varyPaths, shapes, g) = (varyingPaths s, shapesr s, rng s)
      -- Partially apply resampleVState with the params that don't change over a resampling
      resampleVStateConst = resampleVState varyPaths shapes
      sampledResults = take n $ iterateS resampleVStateConst g
      res = minimumBy (lessEnergyOn f) sampledResults
  in updateVState s res

resampleOne :: State -> State
resampleOne s = 
  let (varyPaths, shapes, g) = (varyingPaths s, shapesr s, rng s)
      resampleVStateConst = resampleVState varyPaths shapes
  in updateVState s $ resampleVStateConst g

------- Other possibly-useful utility functions (not currently used)
-- TODO: rewrite these functions to not use the lambdaized overallObjFN
-- | Evaluate the objective function on the varying state (with the penalty weight, which should be the same between state).
-- evalFnOn :: State -> Double
-- evalFnOn s = let optInfo = paramsr s
--                  f       = (overallObjFn optInfo) (rng s) (float2Double $ weight optInfo)
--                  args    = varyingState s
--              in f args
-- | Compare two states and return the one with less energy.
-- lessEnergy :: State -> State -> Ordering
-- lessEnergy s1 s2 = compare (evalFnOn s1) (evalFnOn s2)
---------- List of policies that can be used with the optimizer
-- Policy stops when value is None
-- Note: if there are no objectives/constraints, policy may return an empty list of functions
-- Policy step = one optimization through to convergence
-- TODO: factor out number of policy steps / other boilerplate? or let it remain dynamic?
-- TODO: factor out the weights on the objective functions / method of combination (in genObjFn)
initPolicyParams :: PolicyParams
initPolicyParams =
  PolicyParams {policyState = "", policySteps = 0, currFns = []}

-- initPolicy :: State -> State
-- initPolicy s = -- TODO: make this less verbose
--     let (policyRes, pstate) = (policyFn s) (objFns s) (constrFns s) initPolicyParams in
--     let newFns = DM.fromJust policyRes in
--     let stateWithPolicy = s { paramsr = (paramsr s) { overallObjFn = genObjfn (castTranslation $ transr s) (filter isObjFn newFns)
--                                                                               (filter isConstr newFns) (varyingPaths s) },
--                               policyParams = initPolicyParams { policyState = pstate, currFns = newFns } } in
--     stateWithPolicy
optimizeConstraints :: Policy
optimizeConstraints objfns constrfns params =
  let (pstate, psteps) = (policyState params, policySteps params)
  in if psteps == 0
       then (Just constrfns, "")
       else (Nothing, "") -- Take 1 policy step

optimizeObjectives :: Policy
optimizeObjectives objfns constrfns params =
  let (pstate, psteps) = (policyState params, policySteps params)
  in if psteps == 0
       then (Just objfns, "")
       else (Nothing, "") -- Take 1 policy step

-- This is the typical/old Penrose policy
optimizeSumAll :: Policy
optimizeSumAll objfns constrfns params =
  let (pstate, psteps) = (policyState params, policySteps params)
  in if psteps == 0
       then (Just $ objfns ++ constrfns, "")
       else (Nothing, "") -- Take 1 policy step

optimizeConstraintsThenObjectives :: Policy
optimizeConstraintsThenObjectives objfns constrfns params =
  let (pstate, psteps) = (policyState params, policySteps params)
  in if psteps == 0
       then (Just constrfns, "Constraints") -- Initial policy state
       else if psteps >= 2
              then (Nothing, "Done") -- Just constraints then objectives for now, then done
              else if pstate == "Constraints"
                     then (Just objfns, "Objectives")
                     else if pstate == "Objectives"
                            then (Just constrfns, "Constraints")
                            else error "invalid policy state"

isObjFn f = optType f == Objfn

isConstr f = optType f == Constrfn
-- TODO: does genObjFns work with an empty list?
