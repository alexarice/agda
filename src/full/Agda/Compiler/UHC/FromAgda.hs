{-# LANGUAGE CPP             #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE PatternGuards   #-}

-- | Convert from Agda's internal representation to our auxiliary AST.
--
--
-- The coinduction kit is translated the same way as in MAlonzo:
-- flat = id
-- sharp = id
-- -> There is no runtime representation of Coinductive values.
module Agda.Compiler.UHC.FromAgda where

#if __GLASGOW_HASKELL__ <= 708
import Control.Applicative
import Data.Traversable (traverse)
#endif

import Control.Monad
import Control.Monad.State
import Control.Monad.Reader
import qualified Data.Map as M
import Data.Maybe
import Data.Either
import Data.List

import Agda.Syntax.Internal hiding (Term(..))
import qualified Agda.Syntax.Internal as I
import Agda.Syntax.Literal  as TL
import qualified Agda.Syntax.Treeless as C
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Monad.Builtin
import Agda.TypeChecking.Pretty
import Agda.Utils.List
import qualified Agda.Utils.Pretty as P
import qualified Agda.Utils.HashMap as HMap
import Agda.Syntax.Abstract.Name
import Agda.Syntax.Common

import Agda.Compiler.ToTreeless
import Agda.Compiler.Treeless.NPlusKToPrims
import Agda.Compiler.UHC.Pragmas.Base
import Agda.Compiler.UHC.Pragmas.Parse (coreExprToCExpr)
import Agda.Compiler.UHC.AuxAST as A
import Agda.Compiler.UHC.CompileState
import Agda.Compiler.UHC.ModuleInfo
import Agda.Compiler.UHC.Primitives
import Agda.Compiler.UHC.Core
import Agda.Compiler.UHC.Naming
import Agda.Compiler.UHC.MagicTypes

import Agda.Compiler.UHC.Bridge as CA

import Agda.Utils.Except ( MonadError (catchError) )

#include "undefined.h"
import Agda.Utils.Impossible

opts :: EHCOpts
opts = defaultEHCOpts

-- | Convert from Agda's internal representation to our auxiliary AST.
fromAgdaModule :: ModuleName
    -> [AModuleInfo]     -- Module info of imported modules.
    -> AModuleInterface  -- Transitive module interface of all dependencies.
    -> Interface         -- interface to compile
    -> (AMod -> CompileT TCM a) -- continuation, normally program transforms
    -> TCM (a, AModuleInfo)
fromAgdaModule modNm curModImps transModIface iface cont = do
  kit <- coinductionKit

  let defs = HMap.toList $ sigDefinitions $ iSignature iface

  reportSLn "uhc" 15 "Building name database..."
  defNames <- collectNames defs
  nameMp <- assignCoreNames modNm defNames
  reportSLn "uhc" 25 $ "NameMap for " ++ show modNm ++ ":\n" ++ show nameMp


  (mod', modInfo') <- runCompileT kit modNm curModImps transModIface nameMp (do
    lift $ reportSLn "uhc" 10 "Translate datatypes..."
    -- Translate and add datatype information
    dats <- translateDataTypes defs
    let conMp = buildConMp dats
    addConMap conMp

    lift $ reportSLn "uhc" 25 $ "Constructor Map for " ++ show modNm ++ ":\n" ++ show conMp


    funs' <- evalFreshNameT "nl.uu.agda.from-agda" (concat <$> mapM translateDefn defs)
    let funs = mkLetRec funs' (mkInt opts 0)

    -- additional core/HS imports for the FFI
    additionalImports <- lift getHaskellImportsUHC
    let amod = AMod { xmodName = modNm
                  , xmodFunDefs = funs
                  , xmodDataTys = dats
                  , xmodCrImports = additionalImports
                  }
    cont amod
    )

  return (mod', modInfo')
  where buildConMp :: [ADataTy] -> M.Map QName AConInfo
        buildConMp dts = M.fromList $ concatMap datToConInfo dts
        datToConInfo :: ADataTy -> [(QName, AConInfo)]
        datToConInfo dt = [(xconQName con, AConInfo dt con) | con <- xdatCons dt]

-- | Collect module-level names.
collectNames :: [(QName, Definition)] -> TCM [AgdaName]
collectNames defs = do
  return $ catMaybes $ map collectName defs
  where collectName :: (QName, Definition) -> Maybe AgdaName
        collectName (qnm, def) =
            let ty = case theDef def of
                    (Datatype {}) -> EtDatatype
                    (Function {}) -> EtFunction
                    (Constructor {}) -> EtConstructor
                    (Record {}) -> EtConstructor
                    (Axiom {})  -> EtFunction
                    (Primitive {}) -> EtFunction
                isForeign = isJust $ compiledCore $ defCompiledRep def
            -- builtin/foreign constructors already have a core-level representation, so we don't need any fresh names
            -- but for the datatypes themselves we still want to create the type-dummy function
            in case theDef def of
                  _ | ty == EtConstructor && isForeign -> Nothing
                  _ | otherwise -> Just AgdaName
                        { anName = qnm
                        , anType = ty
                        , anNeedsAgdaExport = True -- TODO, only set this to true for things which are actually exported
                        , anForceName = Nothing -- TODO add pragma to force name
                        }

-- | Collects all datatype information for non-instantiated datatypes.
translateDataTypes :: [(QName, Definition)] -> CompileT TCM [ADataTy]
translateDataTypes defs = do
  kit <- getCoinductionKit
  -- first, collect all constructors
  -- Right elements are foreign datatype constructors,
  -- Lefts are normally compiled Agda datatype constructors.
  constrMp <- M.unionsWith (++)
    <$> mapM (\(n, def) ->
        case theDef def of
            d@(Constructor {}) -> do
                let isForeign = compiledCore $ defCompiledRep def
                arity' <- lift $ (fst <$> conArityAndPars n)
                let conFun = ADataCon n
                con <- case isForeign of
                    (Just (CrConstr crcon)) -> return $ Right (conFun $ coreConstrToCTag crcon arity')
                    (Nothing)   -> do
                        conCrNm <- getCoreName1 n
                        return $ Left (\tyCrNm tag -> conFun (mkCTag tyCrNm conCrNm tag arity'))
                    _ -> __IMPOSSIBLE__
                return $ M.singleton (conData d) [con]
            _ -> return M.empty
        ) defs

  -- now extract all datatypes, and use the constructor info
  -- collected before
  let handleDataRecDef = (\n def -> do
            let isForeign = compiledCore $ defCompiledRep def
            let cons = M.findWithDefault [] n constrMp
            case (isForeign, partitionEithers cons) of
              (Just (CrType crty), ([], cons')) -> do -- foreign datatypes (COMPILED_DATA_UHC)
                    let (tyNm, impl) = case crty of
                                CTMagic mgcNm -> let tyNm' = fst $ getMagicTypes M.! mgcNm
                                        in (tyNm', ADataImplMagic mgcNm)
                                CTNormal tyNm' -> (Just $ mkHsName1 tyNm', ADataImplForeign)
                    return $ Just (ADataTy tyNm n cons' impl)
              (Nothing, (cons', [])) -> do
                    tyCrNm <- getCoreName1 n
                    -- build ctags, assign tag numbers
                    let cons'' = map (\((conFun), i) -> conFun tyCrNm i) (zip cons' [0..])
                    return $ Just (ADataTy (Just tyCrNm) n cons'' ADataImplNormal)
              _ -> __IMPOSSIBLE__ -- datatype is builtin <=> all constructors have to be builtin
              )

  catMaybes <$> mapM
    (\(n, def) -> case theDef def of
        (Record{}) | Just n /= (nameOfInf <$> kit)
                -> handleDataRecDef n def
        -- coinduction kit gets erased in the translation to AuxAST
        (Datatype {})
                -> handleDataRecDef n def
        _       -> return Nothing
    ) defs


-- | Translate an Agda definition to an UHC Core function where applicable
translateDefn :: (QName, Definition) -> FreshNameT (CompileT TCM) [CBind]
translateDefn (n, defini) = do

  crName <- lift $ getCoreName n
  let crRep = compiledCore $ defCompiledRep defini
  kit <- lift getCoinductionKit
  case theDef defini of
    d@(Datatype {}) -> do -- become functions returning unit
        vars <- replicateM (dataPars d + dataIxs d) freshLocalName
        return [mkBind1 (fromMaybe __IMPOSSIBLE__ crName) (mkLam vars $ mkUnit opts)]
    (Function{}) | Just n == (nameOfFlat <$> kit) -> do
        (\x -> [x]) <$> mkIdentityFun n "coind-flat" 0
    f@(Function{}) | otherwise -> do
        let ty    = (defType defini)
        lift . lift $ reportSDoc "uhc.fromagda" 5 $ text "compiling fun:" <+> prettyTCM n
        lift . lift $ reportSDoc "uhc.fromagda" 15 $ text "type:" <+> (text . show) ty
        let cc = fromMaybe __IMPOSSIBLE__ $ funCompiled f

        funBody <- convertNPlusK <$> (lift . lift) (ccToTreeless n cc)
        lift $ lift $ reportSDoc "uhc.fromagda" 30 $ text " compiled treeless fun:" <+> (text . show) funBody
        funBody' <- runCompile $ compileTerm funBody
        lift $ lift $ reportSDoc "uhc.fromagda" 30 $ text " compiled AuxAST fun:" <+> (text . show) funBody'

        return [mkBind1 (fromMaybe __IMPOSSIBLE__ crName) funBody']

    Constructor{} | Just n == (nameOfSharp <$> kit) -> do
        (\x -> [x]) <$> mkIdentityFun n "coind-sharp" 0

    (Constructor{}) | otherwise -> do -- become functions returning a constructor with their tag

        case crName of
          (Just _) -> do
                    conInfo <- lift $ getConstrInfo n
                    let conCon = aciDataCon conInfo
                        arity' = xconArity conCon

                    vars <- replicateM arity' freshLocalName
                    let conWrapper = mkLam vars (mkTagTup (xconCTag conCon) $ map mkVar vars)

                    return [mkBind1 (ctagCtorName $ xconCTag conCon) conWrapper]
          Nothing -> return [] -- either foreign or builtin type. We can just assume existence of the wrapper functions then.

    r@(Record{}) -> do
        vars <- replicateM (recPars r) freshLocalName
        return [mkBind1 (fromMaybe __IMPOSSIBLE__ crName) (mkLam vars $ mkUnit opts)]
    (Axiom{}) -> do -- Axioms get their code from COMPILED_UHC pragmas
        case crRep of
            Nothing -> return [mkBind1 (fromMaybe __IMPOSSIBLE__ crName)
                (coreError $ "Axiom " ++ show n ++ " used but has no computation.")]
            Just (CrDefn x) -> do
                        x' <- case coreExprToCExpr x of
                                -- This can only happen if an *.agdai file was generated by an Agda version
                                -- without UHC support enabled.
                                Left err -> internalError $ "Invalid COMPILED_UHC pragma value: " ++ err
                                Right y -> return y
                        return [mkBind1 (fromMaybe __IMPOSSIBLE__ crName) x']
            _ -> __IMPOSSIBLE__

    p@(Primitive{}) -> do -- Primitives use primitive functions from UHC.Agda.Builtins of the same name.

      case primName p `M.lookup` primFunctions of
        Nothing     -> internalError $ "Primitive " ++ show (primName p) ++ " declared, but no such primitive exists."
        (Just expr) -> do
                expr' <- lift expr
                return [mkBind1 (fromMaybe __IMPOSSIBLE__ crName) expr']
  where
    -- | Produces an identity function, optionally ignoring the first n arguments.
    mkIdentityFun :: Monad m => QName
        -> String -- ^ comment
        -> Int      -- ^ How many arguments to ignore.
        -> FreshNameT (CompileT m) CBind
    mkIdentityFun nm comment ignArgs = do
        crName <- lift $ getCoreName1 nm
        xs <- replicateM (ignArgs + 1) freshLocalName
        return $ mkBind1 crName (mkLam xs (mkVar $ last xs))


runCompile :: NM a -> FreshNameT (CompileT TCM) a
runCompile r = do
  r `runReaderT` (NMEnv [])

data NMEnv = NMEnv
  { nmEnv :: [HsName] -- maps de-bruijn indices to names
  }

type NM = ReaderT NMEnv (FreshNameT (CompileT TCM))


addToEnv :: [HsName] -> NM a -> NM a
addToEnv nms cont =
  local (\e -> e { nmEnv = nms ++ (nmEnv e) }) cont


natKit :: TCM (Maybe QName)
natKit = do
    I.Def nat _ <- primNat
    return $ Just nat
  `catchError` \_ -> return Nothing

-- | Translate the actual Agda terms, with an environment of all the bound variables
--   from patternmatching. Agda terms are in de Bruijn so we just check the new
--   names in the position.
compileTerm :: C.TTerm -> NM CExpr
compileTerm term = do
  natKit' <- lift $ lift $ lift natKit
  case term of
    C.TPrim t -> return $ compilePrim t
    C.TVar x -> do
      nm <- fromMaybe __IMPOSSIBLE__ . (!!! x) <$> asks nmEnv
      return $ mkVar nm
    C.TDef nm -> do
      nm' <- lift . lift $ getCoreName1 nm
      return $ mkVar nm'
    C.TApp t xs -> do
      mkApp <$> compileTerm t <*> mapM compileTerm xs
    C.TLam t -> do
       name <- lift freshLocalName
       addToEnv [name] $ do
         mkLam [name] <$> compileTerm t
    C.TLit l -> return $ litToCore l
    C.TCon c -> do
        con <- lift . lift $ getConstrFun c
        return $ mkVar con
    C.TLet x body -> do
        nm <- lift freshLocalName
        mkLet1Plain nm
          <$> compileTerm x
          <*> addToEnv [nm] (compileTerm body)
    C.TCase sc (C.CTData dt) def alts | Just dt /= natKit'-> do
      -- normal constructor case
      caseScr <- lift freshLocalName
      defVar <- lift freshLocalName
      def' <- compileTerm def

      branches <- traverse compileConAlt alts
      defBranches <- defaultBranches dt alts (mkVar defVar)
      let cas = mkCase (mkVar caseScr) (branches ++ defBranches)
      caseScr' <- compileTerm (C.TVar sc)

      return $ mkLet1Plain defVar def' (mkLet1Strict caseScr caseScr' cas)

    C.TCase sc ct def alts | otherwise -> do
      -- cases on literals
      sc <- compileTerm (C.TVar sc)
      var <- lift freshLocalName
      def <- compileTerm def

      css <- buildPrimCases eq (mkVar var) alts def
      return $ mkLet1Strict var sc css
      where
        eq :: CExpr
        eq = case ct of
          C.CTChar -> mkVar $ primFunNm "primCharEquality"
          C.CTString -> mkVar $ primFunNm "primStringEquality"
          C.CTQName -> mkVar $ primFunNm "primQNameEquality"
          C.CTData nm | Just nm == natKit' -> mkVar $ primFunNm "primIntegerEquality"
          _ -> __IMPOSSIBLE__

    C.TUnit -> unit
    C.TSort -> unit
    C.TErased -> unit
    C.TError e -> return $ case e of
      C.TUnreachable q -> coreError $ "Unreachable code reached in " ++ P.prettyShow q ++ ". This should never happen! Crashing..."
  where unit = return $ mkUnit opts


buildPrimCases :: CExpr -- ^ equality function
    -> CExpr    -- ^ case scrutinee (in WHNF)
    -> [C.TAlt]
    -> CExpr    -- ^ default value
    -> NM CExpr
buildPrimCases _ _ [] def = return def
buildPrimCases eq scr (b:brs) def = do
    var <- lift     freshLocalName
    e' <- compileTerm (C.aBody b)
    rec' <- buildPrimCases eq scr brs def

    let lit = litToCore $ C.aLit b
        eqTest = mkApp eq [scr, lit]

    return $ mkLet1Strict var eqTest (mkIfThenElse (mkVar var) e' rec')

-- move to UHC Core API
mkIfThenElse :: CExpr -> CExpr -> CExpr -> CExpr
mkIfThenElse c t e = mkCase c [b1, b2]
  where b1 = mkAlt (mkPatCon (ctagTrue opts) mkPatRestEmpty []) t
        b2 = mkAlt (mkPatCon (ctagFalse opts) mkPatRestEmpty []) e

compileConAlt :: C.TAlt -> NM CAlt
compileConAlt a =
  makeConAlt (C.aCon a)
    (\vars -> addToEnv (reverse vars) $ compileTerm (C.aBody a))

makeConAlt :: QName -> ([HsName] -> NM CExpr) -> NM CAlt
makeConAlt con mkBody = do
  conInfo <- aciDataCon <$> (lift . lift) (getConstrInfo con)
  vars <- lift $ replicateM (xconArity conInfo) freshLocalName
  body <- mkBody vars

  let patFlds = [mkPatFldBind (mkHsName [] "", mkInt opts i) (mkBind1Nm1 v) | (i, v) <- zip [0..] vars]
  return $ mkAlt (mkPatCon (xconCTag conInfo) mkPatRestEmpty patFlds) body

-- | Constructs an alternative for all constructors not explicitly matched by a branch.
defaultBranches :: QName -> [C.TAlt] -> CExpr -> NM [CAlt]
defaultBranches dt alts def = do
  dtCons <- getCons . theDef <$> (lift . lift . lift) (getConstInfo dt)
  let altCons = map C.aCon alts
      missingCons = dtCons \\ altCons

  mapM (\a -> makeConAlt a (\_ -> return def)) missingCons
  where
    getCons r@(Record{}) = [recCon r]
    getCons d@(Datatype{}) = dataCons d
    getCons _ = __IMPOSSIBLE__


litToCore :: Literal -> CExpr
litToCore (LitInt _ i)   = mkApp (mkVar $ primFunNm "primIntegerToNat") [mkInteger opts i]
litToCore (LitString _ s) = mkString opts s
litToCore (LitChar _ c)  = mkChar c
-- TODO this is just a dirty work around
litToCore (LitFloat _ f) = mkApp (mkVar $ primFunNm "primMkFloat") [mkString opts (show f)]
litToCore (LitQName _ q) = mkApp (mkVar $ primFunNm "primMkQName")
                             [mkInteger opts n, mkInteger opts m, mkString opts $ P.prettyShow q]
  where NameId n m = nameId $ qnameName q

coreError :: String -> CExpr
coreError msg = mkError opts $ "Fatal error: " ++ msg

compilePrim :: C.TPrim -> CExpr
compilePrim C.PDiv = mkVar $ primFunNm "primIntegerDiv"
compilePrim C.PMod = mkVar $ primFunNm "primIntegerMod"
compilePrim C.PSub = mkVar $ primFunNm "primIntegerMinus"
compilePrim C.PAdd = mkVar $ primFunNm "primIntegerPlus"
compilePrim C.PIf  = mkVar $ primFunNm "primIfThenElse"
compilePrim C.PGeq = mkVar $ primFunNm "primIntegerGreaterOrEqual"
