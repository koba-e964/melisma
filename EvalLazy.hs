{-# LANGUAGE BangPatterns #-}
module EvalLazy where

import Control.Monad.Except
import Control.Monad.State
import Control.Monad.Primitive
import qualified Data.Map as Map
import Data.Primitive.MutVar

import CDef hiding (Value, Env)

type Value = ValueLazy
type Env m = EnvLazy m

type EV m = ExceptT EvalError (StateT (EnvLazy m) m)
liftToEV :: (PrimMonad m, Monad m) => m a -> EV m a
liftToEV = lift . lift

op2Int :: (PrimMonad m, Monad m) => (Int -> Int -> Int) -> (ValueLazy m) -> (ValueLazy m) -> EV m (ValueLazy m)
op2Int f (VLInt v1) (VLInt v2) = return $ VLInt (f v1 v2)
op2Int _ _v1 _v2 = evalError $ "int required"

-- The same as op2Int, but checks the second argument and returns error if it is 0.
op2IntDiv :: (PrimMonad m, Monad m) => (Int -> Int -> Int) -> (ValueLazy m) -> (ValueLazy m) -> EV m (ValueLazy m)
op2IntDiv f (VLInt v1) (VLInt v2)
  | v2 == 0   = evalError $ "Division by zero: " ++ show v1 ++ " / 0"
  | otherwise = return $ VLInt (f v1 v2)
op2IntDiv _ _v1 _v2 = evalError $ "int required"

op2IntBool :: (PrimMonad m, Monad m) => (Int -> Int -> Bool) -> (ValueLazy m) -> (ValueLazy m) -> EV m (ValueLazy m)
op2IntBool f (VLInt v1) (VLInt v2) = return $ VLBool (f v1 v2)
op2IntBool _ _v1 _v2 = evalError $ "int required"


evalError :: (PrimMonad m, Monad m) => String -> EV m a
evalError str = throwError $ EvalError $ str

eval :: (PrimMonad m, Monad m) => Expr -> EV m (ValueLazy m)
eval (EConst (VInt v)) = return $ VLInt v
eval (EConst (VBool v)) = return $ VLBool v
eval (EConst _) = error "(>_<) weird const expression..."
eval (EVar (Name name)) = do
    env <- get
    case Map.lookup name env of
      Just thunk -> do
        result <- evalThunk thunk
	return result
      Nothing    -> evalError $ "Unbound variable: " ++ name
eval (EAdd v1 v2) = join $ op2Int (+) `liftM` (eval v1) `ap` (eval v2)
eval (ESub v1 v2) = join $ op2Int (-) `liftM` (eval v1) `ap` (eval v2)
eval (EMul v1 v2) = join $ op2Int (*) `liftM` (eval v1) `ap` (eval v2)
eval (EDiv v1 v2) = join $ op2IntDiv div `liftM` (eval v1) `ap` (eval v2)
eval (EMod v1 v2) = join $ op2IntDiv mod `liftM` (eval v1) `ap` (eval v2)
eval (ELt e1 e2)  = join $ op2IntBool (<) `liftM` (eval e1) `ap` (eval e2)
eval (EEq e1 e2)  = join $ op2IntBool (==) `liftM` (eval e1) `ap` (eval e2)
eval (EIf vc v1 v2) = do
  cond <- eval vc
  case cond of
    VLBool b -> if b then (eval v1) else (eval v2)
    _	    -> evalError "EIf"
eval (ELet (Name name) ei eo) = do
    env <- get
    thunk <- liftToEV $ newMutVar (Thunk env ei)
    let newenv = Map.insert name thunk env
    put newenv
    res <- eval eo
    put env
    return res
eval (ERLets bindings expr) = do
     env <- get
     newenv <- getNewEnvInRLets bindings env
     put newenv
     ret <- eval expr
     put env
     return ret
eval (EMatch expr patex) = do
     env <- get
     thunk <- liftToEV $ newMutVar $ Thunk env expr
     tryMatchAll thunk env patex
eval (EFun name expr) = do
     env <- get
     return $ VLFun name env expr
eval (EApp func argv) = do
     env <- get
     join $ evalApp `liftM` (eval func) `ap` liftToEV (newMutVar (Thunk env argv))
eval (ECons e1 e2) = do
     env <- get
     t1 <- liftToEV $ newMutVar $ Thunk env e1
     t2 <- liftToEV $ newMutVar $ Thunk env e2
     return $ VLCons t1 t2
eval (EPair e1 e2) = do
     env <- get
     t1 <- liftToEV $ newMutVar $ Thunk env e1
     t2 <- liftToEV $ newMutVar $ Thunk env e2
     return $ VLPair t1 t2
eval ENil          = return VLNil
eval (ESeq ea eb)  = do
     _ <- eval ea
     eval eb
eval (EStr str) = return $ VLStr str

evalApp :: (PrimMonad m, Monad m) => (ValueLazy m) -> (Thunk m) -> EV m (ValueLazy m)
evalApp fval ath =
  case fval of
    VLFun (Name param) fenv expr -> do
      oldenv <- get
      put $ Map.insert param ath fenv
      ret <- eval expr
      put oldenv
      return ret
    _others                      -> evalError $ "app: not a function" 

getNewEnvInRLets :: (PrimMonad m, Monad m) => [(Name, Expr)] -> EnvLazy m -> EV m (EnvLazy m)
getNewEnvInRLets bindings oldenv = mnewenv where
  mnewenv = sub oldenv bindings
  sub env [] = return env
  sub env ((Name fname, fexpr) : rest) = do
        thunk <- liftToEV $ newMutVar $ Thunk env (ERLets bindings fexpr)
        sub (Map.insert fname thunk env) rest

tryMatchAll :: (PrimMonad m, Monad m) => Thunk m -> EnvLazy m -> [(Pat, Expr)] -> EV m (ValueLazy m)
tryMatchAll _    _  []                   = evalError "Matching not exhaustive"
tryMatchAll thunk env ((pat, expr) : rest) = do
  pickOne <- tryMatch thunk env pat
  case pickOne of
    Nothing     -> tryMatchAll thunk env rest
    Just newenv -> do
       put newenv
       ret <- eval expr
       put env
       return ret

tryMatch :: (PrimMonad m, Monad m) => (Thunk m) -> EnvLazy m -> Pat -> EV m (Maybe (EnvLazy m))
tryMatch thunk env pat = case pat of
  PConst (VBool b) -> do
    val <- evalThunk thunk
    case val of
      VLBool c -> if c == b then return $ Just env else return Nothing
      _	       -> return Nothing
  PConst (VInt b) -> do
    val <- evalThunk thunk
    case val of
      VLInt c -> if c == b then return $ Just env else return Nothing
      _	      -> return Nothing
  PConst _     -> error "weird const pattern... (>_<)"
  PVar (Name vname) -> return $ Just $! Map.insert vname thunk env
  PCons pcar pcdr   -> do
    val <- evalThunk thunk
    case val of
      VLCons vcar vcdr -> do
        ex <- tryMatch vcar env pcar
        ey <- tryMatch vcdr env pcdr
        return $ do
          mex <- ex
          mey <- ey
          return $! Map.union mey (Map.union mex env)
      _notused       -> return Nothing
  PPair pfst psnd   -> do
    val <- evalThunk thunk
    case val of
      VLPair vfst vsnd -> do
        ex <- tryMatch vfst env pfst
        ey <- tryMatch vsnd env psnd
        return $ do
          mex <- ex
          mey <- ey
          return $! Map.union mey (Map.union mex env)
      _notused         -> return Nothing
  PNil              -> do
    val <- evalThunk thunk
    case val of
      VLNil  -> return $ Just env
      _      -> return Nothing

evalThunk :: (PrimMonad m, Monad m) => (Thunk m) -> EV m (ValueLazy m)
evalThunk thunk = do
  dat <- liftToEV $ readMutVar thunk
  case dat of
    Thunk env expr -> do
      oldenv <- get
      put env
      ret <- eval expr
      put oldenv
      liftToEV $ writeMutVar thunk (ThVal ret)
      return ret
    ThVal value -> return value

showValueLazy :: (PrimMonad m, Monad m) => (ValueLazy m) -> EV m String
showValueLazy (VLInt  v) = return $ show v
showValueLazy (VLBool v) = return $ show v
showValueLazy (VLFun (Name name) _ _) = return $ "fun " ++ name ++ " -> (expr)" 
showValueLazy (VLCons tcar tcdr) = do
    inner <- sub tcar tcdr (10 :: Int)
    return $ "[" ++ inner ++ "]" where
    sub _ _    0 = return "..."
    sub t1 tcdr' n = do
      v1 <- evalThunk t1
      vcdr <- evalThunk tcdr'
      case vcdr of
        VLNil -> showValueLazy v1
        VLCons t2 t3 -> do
          sv <- showValueLazy v1
          sr <- sub t2 t3 (n-1)
          return $ sv ++ ", " ++ sr
        _     -> error "(>_<) < weird... the last cell of the list is not nil..."
showValueLazy (VLStr str) = return str
showValueLazy (VLPair a b) = do
    va <- evalThunk a
    sa <- showValueLazy va
    vb <- evalThunk b
    sb <- showValueLazy vb
    return $ "(" ++ sa ++ ", " ++ sb ++ ")"
showValueLazy VLNil = return "[]"

