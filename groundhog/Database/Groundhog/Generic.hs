{-# LANGUAGE FlexibleContexts, ExistentialQuantification, ScopedTypeVariables, MultiParamTypeClasses, FlexibleInstances #-}

-- | This helper module is intended for use by the backend creators
module Database.Groundhog.Generic
  ( 
  -- * Migration
    createMigration
  , executeMigration
  , executeMigrationSilent
  , executeMigrationUnsafe
  , runMigration
  , runMigrationSilent
  , runMigrationUnsafe
  , getQueries
  , printMigration
  , mergeMigrations
  -- * Helpers for running Groundhog actions
  , HasConn
  , runDb
  , runDbConn
  , runDbConnNoTransaction
  , withSavepoint
  -- * Helper functions for defining *PersistValue instances
  , primToPersistValue
  , primFromPersistValue
  , primToPurePersistValues
  , primFromPurePersistValues
  , primToSinglePersistValue
  , primFromSinglePersistValue
  , pureToPersistValue
  , pureFromPersistValue
  , singleToPersistValue
  , singleFromPersistValue
  , toSinglePersistValueUnique
  , fromSinglePersistValueUnique
  , toPersistValuesUnique
  , fromPersistValuesUnique
  , toSinglePersistValueAutoKey
  , fromSinglePersistValueAutoKey
  , failMessage
  , failMessageNamed
  -- * Other
  , bracket
  , finally
  , onException
  , PSFieldDef(..)
  , applyDbTypeSettings
  , findOne
  , replaceOne
  , matchElements
  , haveSameElems
  , mapAllRows
  , phantomDb
  , getAutoKeyType
  , getUniqueFields
  , isSimple
  , deleteByKey
  ) where

import Database.Groundhog.Core

import Control.Applicative ((<|>))
import Control.Monad (liftM, forM_, unless, (>=>))
import Control.Monad.Logger (MonadLogger, NoLoggingT(..))
import Control.Monad.Trans.State (StateT(..))
import Control.Monad.Trans.Control (MonadBaseControl, control, restoreM)
import qualified Control.Exception as E
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.Reader.Class (MonadReader(..))
import Data.Either (partitionEithers)
import Data.Function (on)
import Data.List (partition, sortBy)
import qualified Data.Map as Map
import System.IO (hPutStrLn, stderr)

-- | Produce the migrations but not execute them. Fails when an unsafe migration occurs.
createMigration :: Monad m => Migration m -> m NamedMigrations
createMigration m = liftM snd $ runStateT m Map.empty

-- | Returns either a list of errors in migration or a list of queries
getQueries :: Bool -- ^ True - support unsafe queries
             -> SingleMigration -> Either [String] [String]
getQueries _ (Left errs) = Left errs
getQueries runUnsafe (Right migs) = (if runUnsafe || null unsafe
  then Right $ map (\(_, _, query) -> query) migs'
  else Left $
    [ "Database migration: manual intervention required."
    , "The proposed migration is:"
    ] ++ map (\(isUnsafe, _, query) -> (if isUnsafe then unsafeWarning else replicate (length unsafeWarning) ' ') ++ query) migs') where
  migs' = sortBy (compare `on` \(_, i, _) -> i) migs
  unsafe = filter (\(isUnsafe, _, _) -> isUnsafe) migs'
  unsafeWarning = "<UNSAFE>  "

executeMigration' :: (PersistBackend m, MonadIO m) => Bool -> Bool -> NamedMigrations -> m ()
executeMigration' runUnsafe silent m = do
  let migs = getQueries runUnsafe $ mergeMigrations $ Map.elems m
  case migs of
    Left errs -> fail $ unlines errs
    Right qs -> forM_  qs $ \q -> do
      unless silent $ liftIO $ hPutStrLn stderr $ "Migrating: " ++ q
      executeRaw False q []

-- | Execute the migrations with printing to stderr. Fails when an unsafe migration occurs.
executeMigration :: (PersistBackend m, MonadIO m) => NamedMigrations -> m ()
executeMigration = executeMigration' False False

-- | Execute the migrations. Fails when an unsafe migration occurs.
executeMigrationSilent :: (PersistBackend m, MonadIO m) => NamedMigrations -> m ()
executeMigrationSilent = executeMigration' False True

-- | Execute migrations. Executes the unsafe migrations without warnings and prints them to stderr
executeMigrationUnsafe :: (PersistBackend m, MonadIO m) => NamedMigrations -> m ()
executeMigrationUnsafe = executeMigration' True False

-- | Pretty print the migrations
printMigration :: MonadIO m => NamedMigrations -> m ()
printMigration migs = liftIO $ forM_ (Map.assocs migs) $ \(k, v) -> do
  putStrLn $ "Datatype " ++ k ++ ":"
  case v of
    Left errors -> mapM_ (putStrLn . ("\tError:\t" ++)) errors
    Right sqls  -> do
      let showSql (isUnsafe, _, sql) = (if isUnsafe then "Unsafe:\t" else "Safe:\t") ++ sql
      mapM_ (putStrLn . ("\t" ++) . showSql) sqls

-- | Creates migrations and executes them with printing to stderr. Fails when an unsafe migration occurs.
-- > runMigration m = createMigration m >>= executeMigration
runMigration :: (PersistBackend m, MonadIO m) => Migration m -> m ()
runMigration m = createMigration m >>= executeMigration

-- | Creates migrations and silently executes them. Fails when an unsafe migration occurs.
-- > runMigration m = createMigration m >>= executeMigrationSilent
runMigrationSilent :: (PersistBackend m, MonadIO m) => Migration m -> m ()
runMigrationSilent m = createMigration m >>= executeMigrationSilent

-- | Creates migrations and executes them with printing to stderr. Executes the unsafe migrations without warnings
-- > runMigrationUnsafe m = createMigration m >>= executeMigrationUnsafe
runMigrationUnsafe :: (PersistBackend m, MonadIO m) => Migration m -> m ()
runMigrationUnsafe m = createMigration m >>= executeMigrationUnsafe

-- | Joins the migrations. The result is either all error messages or all queries
mergeMigrations :: [SingleMigration] -> SingleMigration
mergeMigrations ms = case partitionEithers ms of
  ([], statements) -> Right $ concat statements
  (errors, _)      -> Left  $ concat errors

failMessage :: PersistField a => a -> [PersistValue] -> String
failMessage a = failMessageNamed (persistName a)

failMessageNamed :: String -> [PersistValue] -> String
failMessageNamed name xs = "Invalid list for " ++ name ++ ": " ++ show xs

finally :: MonadBaseControl IO m
        => m a -- ^ computation to run first
        -> m b -- ^ computation to run afterward (even if an exception was raised)
        -> m a
finally a sequel = control $ \runInIO ->
                     E.finally (runInIO a)
                               (runInIO sequel)

bracket :: MonadBaseControl IO m
        => m a        -- ^ computation to run first ("acquire resource")
        -> (a -> m b) -- ^ computation to run last ("release resource")
        -> (a -> m c) -- ^ computation to run in-between
        -> m c
bracket before after thing = control $ \runInIO ->
                     E.bracket (runInIO before) (\st -> runInIO $ restoreM st >>= after) (\st -> runInIO $ restoreM st >>= thing)

onException :: MonadBaseControl IO m
        => m a
        -> m b
        -> m a
onException io what = control $ \runInIO -> E.onException (runInIO io) (runInIO what)

data PSFieldDef str = PSFieldDef {
    psFieldName :: str -- bar
  , psDbFieldName :: Maybe str -- SQLbar
  , psDbTypeName :: Maybe str -- inet, NUMERIC(5,2), VARCHAR(50)
  , psExprName :: Maybe str -- BarField
  , psEmbeddedDef :: Maybe [PSFieldDef str]
  , psDefaultValue :: Maybe str
  , psReferenceParent :: Maybe (Maybe ((Maybe str, str), [str]), Maybe ReferenceActionType, Maybe ReferenceActionType)
} deriving (Eq, Show)

applyDbTypeSettings :: PSFieldDef String -> DbType -> DbType
applyDbTypeSettings (PSFieldDef _ _ dbTypeName _ Nothing def psRef) typ = case typ of
  DbTypePrimitive t nullable def' ref -> DbTypePrimitive (maybe t (\typeName -> DbOther $ OtherTypeDef [Left typeName]) dbTypeName) nullable (def <|> def') (applyReferencesSettings psRef ref)
  DbEmbedded emb ref -> DbEmbedded emb (applyReferencesSettings psRef ref)
  t -> t
applyDbTypeSettings (PSFieldDef _ _ _ _ (Just subs) _ psRef) typ = (case typ of
  DbEmbedded (EmbeddedDef _ fields) ref -> DbEmbedded (uncurry EmbeddedDef $ go subs fields) (applyReferencesSettings psRef ref)
  t -> error $ "applyDbTypeSettings: expected DbEmbedded, got " ++ show t) where
  go [] fs = (False, fs)
  go st [] = error $ "applyDbTypeSettings: embedded datatype does not have expected fields: " ++ show st
  go st (field@(fName, fType):fs) = case partition ((== fName) . psFieldName) st of
    ([fDef], rest) -> result where
      (flag, fields') = go rest fs
      result = case psDbFieldName fDef of
        Nothing -> (flag, (fName, applyDbTypeSettings fDef fType):fields')
        Just name' -> (True, (name', applyDbTypeSettings fDef fType):fields')
    _ -> let (flag, fields') = go st fs in (flag, field:fields')

applyReferencesSettings :: Maybe (Maybe ((Maybe String, String), [String]), Maybe ReferenceActionType, Maybe ReferenceActionType) -> Maybe ParentTableReference -> Maybe ParentTableReference
applyReferencesSettings Nothing ref = ref
applyReferencesSettings (Just (parent, onDel, onUpd)) (Just (parent', onDel', onUpd')) = Just (maybe parent' Right parent, onDel <|> onDel', onUpd <|> onUpd')
applyReferencesSettings (Just (Just parent, onDel, onUpd)) Nothing = Just (Right parent, onDel, onUpd)
applyReferencesSettings _ Nothing = error $ "applyReferencesSettings: expected type with reference, got Nothing"

primToPersistValue :: (PersistBackend m, PrimitivePersistField a) => a -> m ([PersistValue] -> [PersistValue])
primToPersistValue a = phantomDb >>= \p -> return (toPrimitivePersistValue p a:)

primFromPersistValue :: (PersistBackend m, PrimitivePersistField a) => [PersistValue] -> m (a, [PersistValue])
primFromPersistValue (x:xs) = phantomDb >>= \p -> return (fromPrimitivePersistValue p x, xs)
primFromPersistValue xs = (\a -> fail (failMessage a xs) >> return (a, xs)) undefined

primToPurePersistValues :: (DbDescriptor db, PrimitivePersistField a) => proxy db -> a -> ([PersistValue] -> [PersistValue])
primToPurePersistValues p a = (toPrimitivePersistValue p a:)

primFromPurePersistValues :: (DbDescriptor db, PrimitivePersistField a) => proxy db -> [PersistValue] -> (a, [PersistValue])
primFromPurePersistValues p (x:xs) = (fromPrimitivePersistValue p x, xs)
primFromPurePersistValues _ xs = (\a -> error (failMessage a xs) `asTypeOf` (a, xs)) undefined

primToSinglePersistValue :: (PersistBackend m, PrimitivePersistField a) => a -> m PersistValue
primToSinglePersistValue a = phantomDb >>= \p -> return (toPrimitivePersistValue p a)

primFromSinglePersistValue :: (PersistBackend m, PrimitivePersistField a) => PersistValue -> m a
primFromSinglePersistValue a = phantomDb >>= \p -> return (fromPrimitivePersistValue p a)

pureToPersistValue :: (PersistBackend m, PurePersistField a) => a -> m ([PersistValue] -> [PersistValue])
pureToPersistValue a = phantomDb >>= \p -> return (toPurePersistValues p a)

pureFromPersistValue :: (PersistBackend m, PurePersistField a) => [PersistValue] -> m (a, [PersistValue])
pureFromPersistValue xs = phantomDb >>= \p -> return (fromPurePersistValues p xs)

singleToPersistValue :: (PersistBackend m, SinglePersistField a) => a -> m ([PersistValue] -> [PersistValue])
singleToPersistValue a = toSinglePersistValue a >>= \x -> return (x:)

singleFromPersistValue :: (PersistBackend m, SinglePersistField a) => [PersistValue] -> m (a, [PersistValue])
singleFromPersistValue (x:xs) = fromSinglePersistValue x >>= \a -> return (a, xs)
singleFromPersistValue xs = (\a -> fail (failMessage a xs) >> return (a, xs)) undefined

toSinglePersistValueUnique :: forall m v u . (PersistBackend m, PersistEntity v, IsUniqueKey (Key v (Unique u)), PrimitivePersistField (Key v (Unique u)))
                           => u (UniqueMarker v) -> v -> m PersistValue
toSinglePersistValueUnique u v = insertBy u v >> primToSinglePersistValue (extractUnique v :: Key v (Unique u))

fromSinglePersistValueUnique :: forall m v u . (PersistBackend m, PersistEntity v, IsUniqueKey (Key v (Unique u)), PrimitivePersistField (Key v (Unique u)))
                             => u (UniqueMarker v) -> PersistValue -> m v
fromSinglePersistValueUnique _ x = phantomDb >>= \proxy -> getBy (fromPrimitivePersistValue proxy x :: Key v (Unique u)) >>= maybe (fail $ "No data with id " ++ show x) return

toPersistValuesUnique :: forall m v u . (PersistBackend m, PersistEntity v, IsUniqueKey (Key v (Unique u)))
                      => u (UniqueMarker v) -> v -> m ([PersistValue] -> [PersistValue])
toPersistValuesUnique u v = insertBy u v >> toPersistValues (extractUnique v :: Key v (Unique u))

fromPersistValuesUnique :: forall m v u . (PersistBackend m, PersistEntity v, IsUniqueKey (Key v (Unique u)))
                        => u (UniqueMarker v) -> [PersistValue] -> m (v, [PersistValue])
fromPersistValuesUnique _ xs = fromPersistValues xs >>= \(k, xs') -> getBy (k :: Key v (Unique u)) >>= maybe (fail $ "No data with id " ++ show xs) (\v -> return (v, xs'))

toSinglePersistValueAutoKey :: forall m v . (PersistBackend m, PersistEntity v, PrimitivePersistField (AutoKey v))
                            => v -> m PersistValue
toSinglePersistValueAutoKey a = insertByAll a >>= primToSinglePersistValue . either id id

fromSinglePersistValueAutoKey :: forall m v . (PersistBackend m, PersistEntity v, PrimitivePersistField (Key v BackendSpecific))
                              => PersistValue -> m v
fromSinglePersistValueAutoKey x = phantomDb >>= \p -> get (fromPrimitivePersistValue p x :: Key v BackendSpecific) >>= maybe (fail $ "No data with id " ++ show x) return

replaceOne :: (Eq x, Show x) => String -> (a -> x) -> (b -> x) -> (a -> b -> b) -> a -> [b] -> [b]
replaceOne what getter1 getter2 apply a bs = case filter ((getter1 a ==) . getter2) bs of
  [_] -> map (\b -> if getter1 a == getter2 b then apply a b else b) bs
  []  -> error $ "Not found " ++ what ++ " with name " ++ show (getter1 a)
  _   -> error $ "Found more than one " ++ what ++ " with name " ++ show (getter1 a)

findOne :: (Eq x, Show x) => String -> (a -> x) -> x -> [a] -> a
findOne what getter x as = case filter ((x ==) . getter) as of
  [a] -> a
  []  -> error $ "Not found " ++ what ++ " with name " ++ show x
  _   -> error $ "Found more than one " ++ what ++ " with name " ++ show x

-- | Returns only old elements, only new elements, and matched pairs (old, new).
-- The new ones exist only in datatype, the old are present only in DB, match is typically by name (the properties of the matched elements may differ).
matchElements :: Show a => (a -> b -> Bool) -> [a] -> [b] -> ([a], [b], [(a, b)])
matchElements eq oldElems newElems = foldr f (oldElems, [], []) newElems where
  f new (olds, news, matches) = case partition (`eq` new) olds of
    ([], rest) -> (rest, new:news, matches)
    ([old], rest) -> (rest, news, (old, new):matches)
    (xs, _) -> error $ "matchElements: more than one element matched " ++ show xs

haveSameElems :: Show a => (a -> b -> Bool) -> [a] -> [b] -> Bool
haveSameElems p xs ys = case matchElements p xs ys of
  ([], [], _) -> True
  _           -> False

mapAllRows :: Monad m => ([PersistValue] -> m a) -> RowPopper m -> m [a]
mapAllRows f pop = go where
  go = pop >>= maybe (return []) (f >=> \a -> liftM (a:) go)

phantomDb :: PersistBackend m => m (proxy (PhantomDb m))
phantomDb = return $ error "phantomDb"

getAutoKeyType :: DbDescriptor db => proxy db -> DbTypePrimitive
getAutoKeyType proxy = case dbType proxy ((undefined :: proxy db -> AutoKeyType db) proxy) of
  DbTypePrimitive t _ _ _ -> t
  t -> error $ "autoKeyType: unexpected key type " ++ show t

getUniqueFields :: UniqueDef' str (Either field str) -> [field]
getUniqueFields (UniqueDef _ _ uFields) = map (either id (error "A unique key may not contain expressions")) uFields

isSimple :: [ConstructorDef] -> Bool
isSimple [_] = True
isSimple _   = False

-- | This class helps to shorten the type signatures of user monadic code.
class (MonadIO m, MonadLogger m, MonadBaseControl IO m, MonadReader cm m, ConnectionManager cm conn) => HasConn m cm conn
instance (MonadIO m, MonadLogger m, MonadBaseControl IO m, MonadReader cm m, ConnectionManager cm conn) => HasConn m cm conn

-- | It helps to run database operations within an application monad.
runDb :: HasConn m cm conn => DbPersist conn m a -> m a
runDb f = ask >>= withConn (runDbPersist f)

-- | Runs action within connection. It can handle a simple connection, a pool of them, etc.
runDbConn :: (MonadBaseControl IO m, MonadIO m, ConnectionManager cm conn) => DbPersist conn m a -> cm -> m a
runDbConn f cm = withConn (runDbPersist f) cm

-- | It is similar to `runDbConn` but runs action without transaction. It can be useful if you use Groundhog within IO monad or in other cases when you cannot put `PersistBackend` instance into your monad stack.
--
-- @
-- flip withConn cm $ \\conn -> liftIO $ do
--   -- transaction is already opened by withConn at this point
--   someIOAction
--   getValuesFromIO $ \\value -> runDbConnNoTransaction (insert_ value) conn
-- @
runDbConnNoTransaction :: (MonadBaseControl IO m, MonadIO m, ConnectionManager cm conn) => DbPersist conn m a -> cm -> m a
runDbConnNoTransaction f cm = withConnNoTransaction (runDbPersist f) cm

-- | It helps to run 'withConnSavepoint' within a monad.
withSavepoint :: (HasConn m cm conn, SingleConnectionManager cm conn, Savepoint conn) => String -> m a -> m a
withSavepoint name m = ask >>= withConnNoTransaction (withConnSavepoint name m)

{-# DEPRECATED deleteByKey "Use deleteBy instead" #-}
deleteByKey :: (PersistBackend m, PersistEntity v, PrimitivePersistField (Key v BackendSpecific)) => Key v BackendSpecific -> m ()
deleteByKey = deleteBy
