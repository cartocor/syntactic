-- | Basic optimization
module Language.Syntactic.Constructs.Binding.Optimize where



import Control.Monad.Writer
import Data.Set as Set
import Data.Typeable

import Language.Syntactic
import Language.Syntactic.Constructs.Binding
import Language.Syntactic.Constructs.Condition
import Language.Syntactic.Constructs.Construct
import Language.Syntactic.Constructs.Identity
import Language.Syntactic.Constructs.Literal
import Language.Syntactic.Constructs.Tuple



-- | Constant folder
--
-- Given an expression and the statically known value of that expression,
-- returns a (possibly) new expression with the same meaning as the original.
-- Typically, the result will be a 'Literal', if the relevant type constraints
-- are satisfied.
type ConstFolder dom = forall a . ASTF dom a -> a -> ASTF dom a

-- | Basic optimization
class Optimize sym
  where
    -- | Bottom-up optimization of an expression. The optimization performed is
    -- up to each instance, but the intention is to provide a sensible set of
    -- \"always-appropriate\" optimizations. The default implementation
    -- 'optimizeSymDefault' does only constant folding. This constant folding
    -- uses the set of free variables to know when it's static evaluation is
    -- possible. Thus it is possible to help constant folding of other
    -- constructs by pruning away parts of the syntax tree that are known not to
    -- be needed. For example, by replacing (using ordinary Haskell as an
    -- example)
    --
    -- > if True then a else b
    --
    -- with @a@, we don't need to report the free variables in @b@. This, in
    -- turn, can lead to more constant folding higher up in the expression.
    optimizeSym
        :: Optimize' dom
        => ConstFolder dom
        -> (sym sig -> AST dom sig)
        -> sym sig
        -> Args (AST dom) sig
        -> Writer (Set VarId) (ASTF dom (DenResult sig))

  -- The reason for having @dom@ as a class parameter is that many instances
  -- need to put additional constraints on @dom@.

type Optimize' dom =
    ( Optimize dom
    , EvalBind dom
    , AlphaEq dom dom dom [(VarId,VarId)]
    , ConstrainedBy dom Typeable
    )

instance (Optimize sub1, Optimize sub2) => Optimize (sub1 :+: sub2)
  where
    optimizeSym constFold injecter (InjL a) = optimizeSym constFold (injecter . InjL) a
    optimizeSym constFold injecter (InjR a) = optimizeSym constFold (injecter . InjR) a

optimizeM :: Optimize' dom
    => ConstFolder dom
    -> ASTF dom a
    -> Writer (Set VarId) (ASTF dom a)
optimizeM constFold = matchTrans (optimizeSym constFold Sym)

-- | Optimize an expression
optimize :: Optimize' dom => ConstFolder dom -> ASTF dom a -> ASTF dom a
optimize constFold = fst . runWriter . optimizeM constFold

-- | Convenient default implementation of 'optimizeSym' (uses 'evalBind' to
-- partially evaluate)
optimizeSymDefault :: Optimize' dom
    => ConstFolder dom
    -> (sym sig -> AST dom sig)
    -> sym sig
    -> Args (AST dom) sig
    -> Writer (Set VarId) (ASTF dom (DenResult sig))
optimizeSymDefault constFold injecter sym args = do
    (args',vars) <- listen $ mapArgsM (optimizeM constFold) args
    let result = appArgs (injecter sym) args'
        value  = evalBind result
    if Set.null vars
      then return $ constFold result value
      else return result

instance Optimize dom => Optimize (dom :| p)
   where
    optimizeSym cf i (C s) args = optimizeSym cf (i . C) s args

instance Optimize dom => Optimize (dom :|| p)
   where
    optimizeSym cf i (C' s) args = optimizeSym cf (i . C') s args

instance Optimize Identity  where optimizeSym = optimizeSymDefault
instance Optimize Construct where optimizeSym = optimizeSymDefault
instance Optimize Literal   where optimizeSym = optimizeSymDefault
instance Optimize Tuple     where optimizeSym = optimizeSymDefault
instance Optimize Select    where optimizeSym = optimizeSymDefault
instance Optimize Let       where optimizeSym = optimizeSymDefault

instance Optimize Condition
  where
    optimizeSym constFold injecter cond@Condition args@(c :* t :* e :* Nil)
        | Set.null cVars = optimizeM constFold t_or_e
        | alphaEq t e    = optimizeM constFold t
        | otherwise      = optimizeSymDefault constFold injecter cond args
      where
        (c',cVars) = runWriter $ optimizeM constFold c
        t_or_e     = if evalBind c' then t else e

instance Optimize Variable
  where
    optimizeSym _ injecter var@(Variable v) Nil = do
        tell (singleton v)
        return (injecter var)

instance Optimize Lambda
  where
    optimizeSym constFold injecter lam@(Lambda v) (body :* Nil) = do
        body' <- censor (delete v) $ optimizeM constFold body
        return $ injecter lam :$ body'

