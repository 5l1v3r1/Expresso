{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ViewPatterns #-}

----------------------------------------------------------------------
-- Type inference and checking.
--
-- The type system implemented here is a basic Hindley-Milner
-- Algorithm-W with supporting let-bound polymorphism; and polymorphic
-- extensible records and variants with constrained rows.
--
module Expresso.InferType (
      typeInference
    , tiDecl
    , runTI
    , initTIState
    , TI
    , TIState
    ) where

import qualified Data.Map as M
import qualified Data.Set as S

import Control.Applicative ((<$>))
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State
import Data.List (intercalate)
import Data.Monoid

import Expresso.Syntax
import Expresso.Type
import Expresso.Utils

lookupScheme :: Pos -> Name -> TI Scheme
lookupScheme pos name = do
    TypeEnv env <- ask
    case M.lookup name env of
        Just s  -> return s
        Nothing -> throwError $ show pos ++ " : unbound variable: " ++ show name

extendEnv :: M.Map Name Scheme -> TI a -> TI a
extendEnv schemes = local (<> TypeEnv schemes)

removeFromEnv :: Pos -> Bind Name -> Maybe Type -> TI a -> TI a
removeFromEnv pos bind mty =
  case bind of
      Arg x       -> remove [x]
      RecArg xs   -> remove xs
      RecWildcard -> \m -> do
          s <- gets tiSubst
          case apply s <$> mty of
            Just (TRecord r) -> remove (M.keys $ rowToMap r) m
            Just t  -> throwError $ show pos ++ " : record wildcard cannot be bound to type " ++ show (ppType t)
            Nothing -> throwError $ show pos ++ " : unexpected record wildcard"
  where
    remove xs = local $ \(TypeEnv env) ->
        TypeEnv $ foldr M.delete env xs

-- | generalise abstracts a type over all type variables which are free
-- in the type but not free in the given type environment.
generalise :: Type -> TI Scheme
generalise t = do
    s   <- gets tiSubst
    env <- apply s <$> ask
    let t'   = apply s t
    let vars = S.toList ((ftv t') S.\\ (ftv env))
    return $ Scheme vars t'

data TIState = TIState
    { tiSupply :: Int
    , tiSubst  :: Subst
    }

type TI a = ExceptT String (ReaderT TypeEnv (State TIState)) a

runTI :: TI a -> TypeEnv -> TIState -> (Either String a, TIState)
runTI t tEnv tState = runState (runReaderT (runExceptT t) tEnv) tState

initTIState :: TIState
initTIState = TIState { tiSupply = 0, tiSubst = mempty }

newTyVar :: Pos -> Char -> TI Type
newTyVar pos prefix = annPos pos <$> newTyVar' prefix

newTyVarWith :: Pos -> Kind -> Constraint -> Char -> TI Type
newTyVarWith pos k c prefix =
    annPos pos <$> newTyVarWith' k c prefix

newTyVar' :: Char -> TI Type'
newTyVar' = newTyVarWith' Star S.empty

newTyVarWith' :: Kind -> Constraint -> Char -> TI Type'
newTyVarWith' k c prefix = do
  s <- get
  let i = tiSupply s
  put s {tiSupply = i + 1 }
  return (TVar $ TyVar [prefix] i k c)

-- | The instantiation function replaces all bound type variables in a
-- type scheme with fresh type variables.
instantiate :: Pos -> Scheme -> TI Type
instantiate pos (Scheme vars t) = do
  nvars <- mapM (\(TyVar (p:_) _ k c) -> newTyVarWith pos k c p) vars
  let s = mconcat $ zipWith (|->) vars nvars
  return $ apply s t

unify :: Type -> Type -> TI ()
unify t1 t2 = do
  s <- gets tiSubst
  u <- mgu (apply s t1) (apply s t2)
  modify (\st -> st { tiSubst = u <> tiSubst st }) -- TODO lens?

mgu :: Type -> Type -> TI Subst
mgu (TFun l r) (TFun l' r') = do
  s1 <- mgu l l'
  s2 <- mgu (apply s1 r) (apply s1 r')
  return $ s2 <> s1
mgu (TVar u) t@(TVar v) = unionConstraints (getPos t) u v
mgu (TVar v) t = varBind v t
mgu t (TVar v) = varBind v t
mgu TInt TInt = return nullSubst
mgu TBool TBool = return nullSubst
mgu TChar TChar = return nullSubst
mgu (TList u) (TList v) = mgu u v
mgu (TRecord row1) (TRecord row2) = mgu row1 row2
mgu (TVariant row1) (TVariant row2) = mgu row1 row2
mgu TRowEmpty TRowEmpty = return nullSubst
mgu row1@(TRowExtend label1 fieldTy1 rowTail1) row2@TRowExtend{} = do
  (fieldTy2, rowTail2, theta1) <- rewriteRow row2 label1
  -- ^ apply side-condition to ensure termination
  case snd $ toList rowTail1 of
    Just tv | isInSubst tv theta1 -> throwError $ show (getPos row1) ++ " : recursive row type"
    _ -> do
      theta2 <- mgu (apply theta1 fieldTy1) (apply theta1 fieldTy2)
      let s = theta2 <> theta1
      theta3 <- mgu (apply s rowTail1) (apply s rowTail2)
      return $ theta3 <> s
mgu t1 t2 = throwError $
    "Types do not unify\n" ++
    show (getPos t1) ++" : "++ show (ppType t1) ++ " versus\n" ++
    show (getPos t2) ++" : "++ show (ppType t2)

-- | in order to unify two type variables, we must union any lacks constraints
unionConstraints :: Pos -> TyVar -> TyVar -> TI Subst
unionConstraints pos u v
  | u == v    = return nullSubst
  | otherwise =
      case (tyvarKind u, tyvarKind v) of
       (Star, Star) -> return $ u |-> annPos pos (TVar v)
       (Row,  Row)  -> do
         let c = (tyvarConstraint u) `S.union` (tyvarConstraint v)
         r <- newTyVarWith pos Row c 'r'
         return $ mconcat [ u |-> r
                          , v |-> r
                          ]
       _            -> throwError $ show pos ++ " : kind mismatch!"

varBind :: TyVar -> Type -> TI Subst
varBind u t
  | u `S.member` ftv t = throwError $ show (getPos t) ++ " : occur check fails: " ++ tyvarName u ++
                                  " occurs in " ++ show (ppType t)
  | otherwise          = case tyvarKind u of
                           Star -> return $ u |-> t
                           Row  -> varBindRow (getPos t) u t

-- | bind the row tyvar to the row type, as long as the row type does not
-- contain the labels in the tyvar lacks constraint; and propagate these
-- label constraints to the row variable in the row tail, if there is one.
varBindRow :: Pos -> TyVar -> Type -> TI Subst
varBindRow pos u t
  = case S.toList (ls `S.intersection` ls') of
      [] | Nothing <- mv -> return s1
         | Just r1 <- mv -> do
             let c = ls `S.union` (tyvarConstraint r1)
             r2 <- newTyVarWith pos Row c 'r'
             let s2 = r1 |-> r2
             return $ s1 <> s2
      labels             -> throwError $ show pos ++ " : repeated label(s): " ++ intercalate ", " labels
  where
    ls        = tyvarConstraint u
    (ls', mv) = first (S.fromList . map fst) $ toList t
    s1        = u |-> t

rewriteRow :: Type -> Label -> TI (Type, Type, Subst)
rewriteRow (Fix (TRowEmptyF :*: K pos)) newLabel =
  throwError $ show pos ++ " : label " ++ show newLabel ++ " cannot be inserted"
rewriteRow (Fix (TRowExtendF label fieldTy rowTail :*: K pos)) newLabel
  | newLabel == label     = return (fieldTy, rowTail, nullSubst) -- ^ nothing to do
  | TVar alpha <- rowTail = do
      beta  <- newTyVarWith pos Row (lacks newLabel) 'r'
      gamma <- newTyVar pos 'a'
      s     <- varBindRow pos alpha
                    $ withPos pos $ TRowExtendF newLabel gamma beta
      return (gamma, apply s $ withPos pos $ TRowExtendF label fieldTy beta, s)
  | otherwise   = do
      (fieldTy', rowTail', s) <- rewriteRow rowTail newLabel
      return (fieldTy', TRowExtend label fieldTy rowTail', s)
rewriteRow ty _ = error $ "Unexpected type: " ++ show ty

-- | type-inference
ti :: Exp -> TI Type
ti = cata alg
  where
    alg :: (ExpF Name Bind :*: K Pos) (TI Type) -> TI Type
    alg (EVar n :*: K pos) = do
        sigma <- lookupScheme pos n
        instantiate pos sigma
    alg (EPrim prim :*: K pos) = tiPrim pos prim
    alg (ELam b e :*: K pos) = do
        tv <- newTyVar pos 'a'
        schemes <- fmap (Scheme []) <$> tiBinds pos b tv
        removeFromEnv pos b Nothing $
          extendEnv schemes $ do
            t1 <- e
            return $ withPos pos $ TFunF tv t1
    alg (EApp e1 e2 :*: K pos) = do
        t1 <- e1
        t2 <- e2
        tv <- newTyVar pos 'a'
        unify t1 (TFun t2 tv)
        return tv
    alg (ELet b e1 e2 :*: K pos) = do
        t1 <- e1
        removeFromEnv pos b (Just t1) $ do
          schemes <- tiBinds pos b t1 >>= mapM generalise
          extendEnv schemes e2

tiBinds :: Pos -> Bind Name -> Type -> TI (M.Map Name Type)
tiBinds _   (Arg x)       ty = return $ M.singleton x ty
tiBinds pos (RecArg xs)   ty = do
    tvs <- mapM (const $ newTyVar pos 'l') xs
    r   <- newTyVar pos 'r' -- implicit tail
    unify ty (TRecord $ mkRowType r $ zip xs tvs)
    return $ M.fromList $ zip xs tvs
tiBinds pos RecWildcard ty = do
    s <- gets tiSubst
    case apply s ty of
        TRecord r -> return $ rowToMap r
        _         -> throwError $ show pos ++ " : record wildcard cannot bind to type: " ++ show ty

-- used by the Repl
tiDecl :: Pos -> Bind Name -> Exp -> TI TypeEnv
tiDecl pos b e = do
   t <- ti e
   removeFromEnv pos b (Just t) $ do
       schemes <- tiBinds pos b t >>= mapM generalise
       extendEnv schemes ask

tiPrim :: Pos -> Prim -> TI Type
tiPrim pos prim = fmap (annPos pos) $ case prim of
  Int{}                  -> return $ TInt
  Bool{}                 -> return $ TBool
  Char{}                 -> return $ TChar
  String{}               -> return $ TList TChar
  Trace                  -> do
    a <- newTyVar' 'a'
    return $ TFun (TFun (TList TChar) a) a
  ErrorPrim              -> do
    a <- newTyVar' 'a'
    return $ TFun (TList TChar) a
  Neg                    -> return $ unOp TInt
  Add                    -> return $ binOp TInt
  Sub                    -> return $ binOp TInt
  Mul                    -> return $ binOp TInt
  Div                    -> return $ binOp TInt
  FixPrim                -> do
    a <- newTyVar' 'a'
    return $ TFun (TFun a a) a
  FwdComp                -> do
    a <- newTyVar' 'a'
    b <- newTyVar' 'b'
    c <- newTyVar' 'c'
    return $ TFun (TFun a b) (TFun (TFun b c) (TFun a c))
  Cond                   -> do
    a <- newTyVar' 'a'
    return $ TFun TBool (TFun a (TFun a a))
  ListEmpty              -> do
    a <- newTyVar' 'a'
    return $ TList a
  ListCons               -> do
    a <- newTyVar' 'a'
    return $ TFun a (TFun (TList a) (TList a))
  ListFoldr              -> do
    a <- newTyVar' 'a'
    b <- newTyVar' 'b'
    return $ TFun (TFun a (TFun b b)) (TFun b (TFun (TList a) b))
  ListNull               -> do -- TODO not needed if lists have equality
    a <- newTyVar' 'a'
    return $ TFun (TList a) TBool
  ListAppend             -> do
    a <- newTyVar' 'a'
    return $ TFun (TList a) (TFun (TList a) (TList a))
  RecordEmpty            -> return $ TRecord TRowEmpty
  (RecordSelect label)   -> do
    a <- newTyVar' 'a'
    r <- newTyVarWith' Row (lacks label) 'r'
    return $ TFun (TRecord $ TRowExtend label a r) a
  (RecordExtend label)   -> do
    a <- newTyVar' 'a'
    r <- newTyVarWith' Row (lacks label) 'r'
    return $ TFun a (TFun (TRecord r) (TRecord $ TRowExtend label a r))
  (RecordRestrict label) -> do
    a <- newTyVar' 'a'
    r <- newTyVarWith' Row (lacks label) 'r'
    return $ TFun (TRecord $ TRowExtend label a r) (TRecord r)
  EmptyAlt               -> do
      b <- newTyVar' 'b'
      return $ TFun (TVariant TRowEmpty) b
  (VariantInject label)  -> do -- ^ dual of record select
    a <- newTyVar' 'a'
    r <- newTyVarWith' Row (lacks label) 'r'
    return $ TFun a (TVariant $ TRowExtend label a r)
           -- a -> <l:a|r>
  (VariantEmbed label)   -> do -- ^ dual of record restrict
    a <- newTyVar' 'a'
    r <- newTyVarWith' Row (lacks label) 'r'
    return $ TFun (TVariant r) (TVariant $ TRowExtend label a r)
           -- <r> -> <l:a|r>
  (VariantElim label)    -> do
    a <- newTyVar' 'a'
    b <- newTyVar' 'b'
    r <- newTyVarWith' Row (lacks label) 'r'
    return $ TFun (TFun a b)
                  (TFun (TFun (TVariant r) b) (TFun (TVariant $ TRowExtend label a r) b))
                  --  (a -> b) -> (<r> -> b) -> <l:a|r> -> b

  where
    binOp ty = TFun ty (TFun ty ty)
    unOp ty  = TFun ty ty

typeInference :: Exp -> TI Scheme
typeInference e = ti e >>= generalise
