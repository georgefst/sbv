-----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.Provers.Z3
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
--
-- The connection to the Z3 SMT solver
-----------------------------------------------------------------------------

{-# LANGUAGE ScopedTypeVariables #-}

module Data.SBV.Provers.Z3(z3) where

import qualified Control.Exception as C

import Data.Char          (toLower)
import Data.Function      (on)
import Data.List          (sortBy, intercalate, groupBy)
import System.Environment (getEnv)
import qualified System.Info as S(os)

import Data.SBV.Core.AlgReals
import Data.SBV.Core.Data

import Data.SBV.SMT.SMT
import Data.SBV.SMT.SMTLib

import Data.SBV.Utils.Lib (splitArgs)
import Data.SBV.Utils.PrettyNum

-- Choose the correct prefix character for passing options
-- TBD: Is there a more foolproof way of determining this?
optionPrefix :: Char
optionPrefix
  | map toLower S.os `elem` ["linux", "darwin"] = '-'
  | True                                        = '/'   -- windows

-- | The description of the Z3 SMT solver
-- The default executable is @\"z3\"@, which must be in your path. You can use the @SBV_Z3@ environment variable to point to the executable on your system.
-- The default options are @\"-in -smt2\"@, which is valid for Z3 4.1. You can use the @SBV_Z3_OPTIONS@ environment variable to override the options.
z3 :: SMTSolver
z3 = SMTSolver {
           name           = Z3
         , executable     = "z3"
         , options        = map (optionPrefix:) ["nw", "in", "smt2"]

         , engine         = \cfg ctx isSat mbOptInfo qinps skolemMap pgm -> do

                                    execName <-                   getEnv "SBV_Z3"          `C.catch` (\(_ :: C.SomeException) -> return (executable (solver cfg)))
                                    execOpts <- (splitArgs `fmap` getEnv "SBV_Z3_OPTIONS") `C.catch` (\(_ :: C.SomeException) -> return (options (solver cfg)))

                                    let cfg'   = cfg { solver = (solver cfg) {executable = execName, options = addTimeOut (timeOut cfg) execOpts} }
                                        tweaks = case solverTweaks cfg' of
                                                   [] -> ""
                                                   ts -> unlines $ "; --- user given solver tweaks ---" : ts ++ ["; --- end of user given tweaks ---"]

                                        dlim     = printRealPrec cfg'
                                        ppDecLim = "(set-option :pp.decimal_precision " ++ show dlim ++ ")\n"

                                        mkCont     = cont (roundingMode cfg) skolemMap

                                        (nModels, isPareto, mbContScript) =
                                                case mbOptInfo of
                                                  Just (Pareto, _)              -> (1, True,  Nothing)
                                                  Just (Independent, n) | n > 1 -> (n, False, Just (intercalate "\n" (map (mkCont . Just) [0 .. n-1])))
                                                  _                             -> (1, False, Just (mkCont Nothing))

                                        script   = SMTScript {scriptBody = tweaks ++ ppDecLim ++ pgm, scriptModel = mbContScript}

                                        mkResult c em
                                         | isPareto     =               interpretSolverParetoOutput         c em
                                         | nModels == 1 = replicate 1 . interpretSolverOutput               c em
                                         | True         =               interpretSolverOutputMulti  nModels c em

                                    standardSolver cfg' ctx script id (replicate nModels . ProofError cfg') (mkResult cfg' (extractMap isSat qinps))

         , capabilities   = SolverCapabilities {
                                  capSolverName              = "Z3"
                                , mbDefaultLogic             = const Nothing
                                , supportsDefineFun          = True
                                , supportsProduceModels      = True
                                , supportsQuantifiers        = True
                                , supportsUninterpretedSorts = True
                                , supportsUnboundedInts      = True
                                , supportsReals              = True
                                , supportsFloats             = True
                                , supportsDoubles            = True
                                , supportsOptimization       = True
                                , supportsPseudoBooleans     = True
                                , supportsUnsatCores         = True
                                , supportsCustomQueries      = True
                                }
         }
 where cont rm skolemMap mbModelIndex = intercalate "\n" $ wrapModel grabValues
        where grabValues = concatMap extract skolemMap

              modelIndex = case mbModelIndex of
                             Nothing -> ""
                             Just i  -> " :model_index " ++ show i

              wrapModel xs = case mbModelIndex of
                               Just _ -> "(echo \"(sbv_objective_model_marker)\")" : xs
                               _      -> xs

              -- In the skolemMap:
              --    * Left's are universals: i.e., the model should be true for
              --      any of these. So, we simply "echo 0" for these values.
              --    * Right's are existentials. If there are no dependencies (empty list), then we can
              --      simply use get-value to extract it's value. Otherwise, we have to apply it to
              --      an appropriate number of 0's to get the final value.
              extract (Left s)        = ["(echo \"((" ++ show s ++ " " ++ mkSkolemZero rm (kindOf s) ++ "))\")"]
              extract (Right (s, [])) = let g = "(get-value (" ++ show s ++ ")" ++ modelIndex ++ ")" in getVal (kindOf s) g
              extract (Right (s, ss)) = let g = "(get-value ((" ++ show s ++ concat [' ' : mkSkolemZero rm (kindOf a) | a <- ss] ++ "))" ++ modelIndex ++ ")" in getVal (kindOf s) g

              getVal KReal g = ["(set-option :pp.decimal false) " ++ g, "(set-option :pp.decimal true)  " ++ g]
              getVal _     g = [g]

       addTimeOut Nothing  o   = o
       addTimeOut (Just i) o
         | i < 0               = error $ "Z3: Timeout value must be non-negative, received: " ++ show i
         | True                = o ++ [optionPrefix : "T:" ++ show i]

extractMap :: Bool -> [(Quantifier, NamedSymVar)] -> [String] -> SMTModel
extractMap isSat qinps solverLines =
   SMTModel { modelObjectives = map snd $               sortByNodeId $ concatMap (interpretSolverObjectiveLine inps) solverLines
            , modelAssocs     = map snd $ squashReals $ sortByNodeId $ concatMap (interpretSolverModelLine     inps) solverLines
            }
  where sortByNodeId :: [(Int, a)] -> [(Int, a)]
        sortByNodeId = sortBy (compare `on` fst)

        inps -- for "sat", display the prefix existentials. For completeness, we will drop
             -- only the trailing foralls. Exception: Don't drop anything if it's all a sequence of foralls
             | isSat = map snd $ if all (== ALL) (map fst qinps)
                                 then qinps
                                 else reverse $ dropWhile ((== ALL) . fst) $ reverse qinps
             -- for "proof", just display the prefix universals
             | True  = map snd $ takeWhile ((== ALL) . fst) qinps

        squashReals :: [(Int, (String, CW))] -> [(Int, (String, CW))]
        squashReals = concatMap squash . groupBy ((==) `on` fst)
          where squash [(i, (n, cw1)), (_, (_, cw2))] = [(i, (n, mergeReals n cw1 cw2))]
                squash xs = xs

                mergeReals :: String -> CW -> CW -> CW
                mergeReals n (CW KReal (CWAlgReal a)) (CW KReal (CWAlgReal b)) = CW KReal (CWAlgReal (mergeAlgReals (bad n a b) a b))
                mergeReals n a b = bad n a b

                bad n a b = error $ "SBV.Z3: Cannot merge reals for variable: " ++ n ++ " received: " ++ show (a, b)
