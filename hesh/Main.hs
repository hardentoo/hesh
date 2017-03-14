{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}

import qualified Cartel
import qualified Cartel.Ast
import qualified Cartel.Render
import Control.Applicative ((<$>), (<*>))
import Control.Monad (mapM_, liftM, when)
import Control.Exception (catch, throw, SomeException)
import Crypto.Hash (hash, Digest, MD5)
import Data.Aeson (Value(..), ToJSON(..), FromJSON(..), encode, decode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.UTF8 as BU
import Data.Char (isDigit)
import Data.Data (Data)
import Data.Default (def)
import Data.Generics.Uniplate.Data (universeBi, transformBi)
import Data.List (intercalate, find, filter, nub, any, takeWhile, isPrefixOf, unionBy)
import qualified Data.Map.Strict as Map
import Data.Map.Lazy (foldrWithKey)
import Data.Maybe (fromMaybe, catMaybes, isJust)
import Data.Monoid (mempty)
import qualified Data.Text as Text
import Data.Text.Encoding (encodeUtf8, decodeUtf8)
import Data.Typeable (Typeable)
import qualified Data.Version as V
import Distribution.Hackage.DB (readHackage, hackagePath)
import Distribution.PackageDescription (condLibrary, condTreeData, exposedModules)
import Distribution.Text (display)
import Distribution.Version (versionBranch)
import GHC.Generics (Generic)
import Language.Haskell.Exts (parseFileContentsWithMode, ParseMode(..), defaultParseMode, Extension(..), KnownExtension(..), ParseResult(..), fromParseResult)
import Language.Haskell.Exts.Fixity (applyFixities, infix_, infixl_, infixr_)
import Language.Haskell.Exts.Syntax (Module(..), ModuleName(..), ModulePragma(..), ImportDecl(..), QName(..), Name(..), Exp(..), Stmt(..), Type(..), SrcLoc(..), QOp(..))
import Language.Haskell.Exts.Pretty (prettyPrintWithMode, defaultMode, PPHsMode(linePragmas))
import System.Console.CmdArgs (cmdArgs, (&=), help, typ, typDir, args, summary, name)
import System.Directory (getTemporaryDirectory, createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode(..), exitFailure)
import System.FilePath ((</>), (<.>), replaceFileName, takeBaseName)
import System.IO (hPutStrLn, hPutStr, stderr, writeFile, hGetContents, Handle)
import System.Posix.Process (executeFile)
import System.Process (ProcessHandle, waitForProcess, createProcess, CreateProcess(..), shell, proc, StdStream(..))

import Hesh.Process (pipeOps)
import Hesh.Shell (desugar)

data Hesh = Hesh {stdin_ :: Bool
                 ,no_sugar :: Bool
                 ,no_type_hints :: Bool
                 ,compile_only :: Bool
                 ,source_dir :: String
                 ,source_only :: Bool
                 ,verbose :: Bool
                 ,args_ :: [String]
                 } deriving (Data, Typeable, Show, Eq)

hesh = Hesh {stdin_ = False &= help "If this option is present, or if no arguments remain after option process, then the script is read from standard input."
            ,no_sugar = False &= help "Don't expand syntax shortcuts."
            ,no_type_hints = False &= name "t" &= help "Don't add automatic type hints."
            ,compile_only = False &= help "Compile the script but don't run it."
            ,source_dir = def &= name "o" &= typDir &= help "Write to given directory instead of a temporary directory."
            ,source_only = False &= name "x" &= help "Generate expanded source code and cabal file only."
            ,verbose = False &= help "Display more information, such as Cabal output."
            ,args_ = def &= args &= typ "FILE|ARG.."
            } &=
       help "Build/run a hesh script." &=
       summary "Hesh v1.12.1"

main = do
  opts <- cmdArgs hesh
  -- In order to work in shebang mode and to provide a more familiar
  -- commandline interface, we support taking the input filename as an
  -- argument (rather than just relying on the script being provided
  -- on stdin). If no commandline argument is provided, we assume the
  -- script is on stdin.
  let scriptFile = if stdin_ opts || null (args_ opts) then "<stdin>" else head (args_ opts)
      scriptName = if stdin_ opts || null (args_ opts) then "script" else takeBaseName (head (args_ opts))
  (source, args) <- if stdin_ opts || null (args_ opts)
                      then (\x -> (x, args_ opts)) `fmap` BS.getContents
                      else (\x -> (x, tail (args_ opts))) `fmap` BS.readFile (head (args_ opts))
  -- First, get the module -> package+version lookup table.
  p <- modulesPath
  modules <- fromFileCache p =<< modulePackages
  let ast = (if no_type_hints opts then id else defaultToUnit) (parseScript scriptFile (no_sugar opts) source)
      -- Find all qualified module names to add module names to the import list (qualified).
      names = qualifiedNamesFromModule ast
      -- Find any import references.
      imports = importsFromModule ast
      -- Remove aliased modules from the names.
      aliases = catMaybes (map (\ (_, y, _) -> y) imports)
      fqNames = filter (`notElem` aliases) (map fst names)
      -- Insert qualified module usages back into the import list.
      (Module a b pragmas d e importDecls g) = ast
      expandedImports = importDecls ++ map importDeclQualified fqNames ++ if no_sugar opts then [] else (if isJust (find (\(m, _, _) -> m == "Hesh") imports) then [] else [importDeclUnqualified "Hesh"]) ++ if no_type_hints opts then [] else [importDeclQualified "Control.Monad.IO.Class"]
      expandedPragmas = pragmas ++ if no_sugar opts then [] else sugarPragmas
      expandedAst = Module a b expandedPragmas d e expandedImports g
      -- From the imports, build a list of necessary packages.
      -- First, remove fully qualified names that were previously
      -- imported explicitly. This is so that we don't override the
      -- package that might have been selected for that module
      -- manually in the import statement.
      packages = map (packageFromModules modules) (unionBy (\ (x, _, _) (x', _, _) -> x == x') imports (map fqNameModule fqNames) ++ if no_sugar opts then [] else [("Hesh", Nothing, Just "hesh")])
      source' = BU.fromString $ prettyPrintWithMode (defaultMode { linePragmas = True }) expandedAst
      cabal' = BU.fromString $ Cartel.Render.renderNoIndent (cartel opts packages scriptName)
  dir <- if null (source_dir opts)
           then (</> ("hesh-" ++ show (hash source' :: Digest MD5))) `liftM` getTemporaryDirectory
           else return (source_dir opts)
  let sourcePath = dir </> "Main.hs"
      cabalPath = dir </> scriptName <.> "cabal"
  -- Check if the source is different than what exists in the directory already.
  oldSource <- catchAny (BS.readFile sourcePath) (\ _ -> return "")
  oldCabal <- catchAny (BS.readFile cabalPath) (\ _ -> return "")
  when (oldSource /= source' || oldCabal /= cabal') $ do
    createDirectoryIfMissing False dir
    BS.writeFile sourcePath source'
    BS.writeFile cabalPath cabal'
    -- Cabal will complain without a LICENSE file.
    BS.writeFile (dir </> "LICENSE") ""
  if (source_only opts)
    then putStr dir
    else do
      let path = dir </> "dist/build" </> scriptName </> scriptName
      binaryExists <- doesFileExist path
      when (not binaryExists || oldSource /= source' || oldCabal /= cabal') $ do
        callCommandInDir "cabal install --only-dependencies" dir (verbose opts)
        callCommandInDir "cabal build" dir (verbose opts)
      if (compile_only opts)
        then putStr path
        else executeFile path False args Nothing
 where fqNameModule name = (name, Nothing, Nothing)
       sugarPragmas = [LanguagePragma (SrcLoc "<generated>" 0 0) [Ident "TemplateHaskell", Ident "QuasiQuotes", Ident "PackageImports"]]

waitForSuccess :: String -> ProcessHandle -> Maybe Handle -> IO ()
waitForSuccess cmd p out = do
  code <- waitForProcess p
  when (code /= ExitSuccess) $ do
    case out of
      Just o -> hPutStr stderr =<< hGetContents o
      Nothing -> return ()
    hPutStrLn stderr $ cmd ++ ": exited with code " ++ show code
    exitFailure

callCommandInDir :: String -> FilePath -> Bool -> IO ()
callCommandInDir cmd dir verbose' = do
  -- GHC is noisy on stdout. It should go to stderr instead.
  -- TODO: Move this into a more appropriate place. It just
  -- happens to work here.
  (_, out, _, p) <- createProcess (shell cmd) { cwd = Just dir, std_out = (if verbose' then UseHandle stderr else CreatePipe) }
  waitForSuccess cmd p out

callCommand :: FilePath -> [String] -> IO ()
callCommand path args = do
  (_, _, _, p) <- createProcess (proc path args)
  waitForSuccess path p Nothing

catchAny :: IO a -> (SomeException -> IO a) -> IO a
catchAny = catch

-- Read a value from a cache (JSON-encoded file), writing it out if
-- the cached value doesn't exist or is invalid.
fromFileCache :: (FromJSON a, ToJSON a) => FilePath -> a -> IO a
fromFileCache path value = do
  catchAny readCached (\_ -> BL.writeFile path (encode value) >> return value)
 where readCached = do
         d <- BL.readFile path
         case decode d of
           Just x -> return x
           Nothing -> error "Failed to parse JSON."

modulesPath :: IO FilePath
modulesPath = do
  hPath <- hackagePath
  return $ replaceFileName hPath "modules.json"

qualifiedNamesFromModule :: Module -> [(String, String)]
qualifiedNamesFromModule m = [ (mName, name) | Qual (ModuleName mName) (Ident name) <- universeBi m ]

-- This is a helper until Haskell has better defaulting (something like
-- https://ghc.haskell.org/trac/haskell-prime/wiki/Defaulting).
-- It saves adding "IO ()" type declarations in a number of common contexts.
defaultToUnit :: Module -> Module
defaultToUnit = transformBi defaultExpToUnit
 where defaultExpToUnit :: Exp -> Exp
       defaultExpToUnit (Do stmts) = Do (map defaultStmtToUnit stmts)
       defaultExpToUnit exp = exp
       defaultStmtToUnit (Qualifier exp) = Qualifier (defaultQualifiedExpToUnit exp)
       defaultStmtToUnit stmt = stmt
       defaultQualifiedExpToUnit exp = if canDefaultToUnit exp then defaultToUnit exp else exp
       -- do [sh| ... |] => do [sh| ... |] :: IO ()
       canDefaultToUnit (QuasiQuote f _) = f `elem` ["sh", "Hesh.sh"]
       -- do cmd "..." [...] => do cmd "..." [...] :: IO ()
       canDefaultToUnit (App (App (Var f) _) _) = f `elem` functionNames "cmd"
       -- do ... /> "..." => ... /> "..." :: IO ()
       canDefaultToUnit (InfixApp exp1 (QVarOp op) exp2) = op `elem` (concatMap operatorNames pipeOps)
       canDefaultToUnit _ = False
       defaultToUnit exp = ExpTypeSig (SrcLoc "<generated>" 0 0) exp (TyVar (Ident "(Control.Monad.IO.Class.MonadIO m) => m ()"))
       functionNames name = [ UnQual (Ident name)
                            , Qual (ModuleName "Hesh") (Ident name) ]
       operatorNames name = [ UnQual (Symbol name)
                            , UnQual (Ident ("(" ++ name ++ ")"))
                            , Qual (ModuleName "Hesh") (Ident ("(" ++ name ++ ")")) ]

importsFromModule :: Module -> [(String, Maybe String, Maybe String)]
importsFromModule (Module _ _ _ _ _ imports _) = map importName imports
 where importName (ImportDecl _ (ModuleName m) _ _ _ pkg Nothing _) = (m, Nothing, pkg)
       importName (ImportDecl _ (ModuleName m) _ _ _ pkg (Just (ModuleName n)) _) = (m, Just n, pkg)

importDeclQualified :: String -> ImportDecl
importDeclQualified m = ImportDecl (SrcLoc "<generated>" 0 0) (ModuleName m) True False False Nothing Nothing Nothing

importDeclUnqualified :: String -> ImportDecl
importDeclUnqualified m = ImportDecl (SrcLoc "<generated>" 0 0) (ModuleName m) False False False Nothing Nothing Nothing

packageFromModules modules (m, _, Just pkg)
  | pkg == "hesh" = Cartel.package "hesh" Cartel.anyVersion
  | otherwise =
      let parts = Text.splitOn "-" (Text.pack pkg)
      in case parts of
           [_] -> Cartel.package pkg Cartel.anyVersion
           ps -> if Text.all (\c -> isDigit c || c == '.') (last ps)
                   then let version = map (read . Text.unpack) (Text.splitOn "." (last ps))
                            package = Text.unpack (Text.intercalate "-" (init ps))
                        in Cartel.package package (Cartel.eq version)
                   else Cartel.package pkg Cartel.anyVersion
packageFromModules modules (m, _, Nothing)
  | m == "Hesh" || isPrefixOf "Hesh." m = Cartel.package "hesh" Cartel.anyVersion
  | otherwise = constrainedPackage (Map.findWithDefault (error ("Module \"" ++ m ++ "\" not found in Hackage list.")) (Text.pack m) modules)

cartel opts packages name = mempty { Cartel.Ast.properties = properties
                                   , Cartel.Ast.sections = [executable] }
 where properties = mempty
         { Cartel.name         = name
         , Cartel.version      = [0,1]
         , Cartel.cabalVersion = Just (fromIntegral 1, fromIntegral 18)
         , Cartel.buildType    = Just Cartel.simple
         , Cartel.license      = Just Cartel.allRightsReserved
         , Cartel.licenseFile  = "LICENSE"
         , Cartel.category     = "shell"
         }
       executable = Cartel.executable name fields
       fields = [ Cartel.Ast.ExeMainIs "Main.hs"
                , Cartel.Ast.ExeInfo (Cartel.Ast.DefaultLanguage Cartel.Ast.Haskell2010)
                , Cartel.Ast.ExeInfo (Cartel.Ast.BuildDepends ([Cartel.package "base" Cartel.anyVersion] ++ packages))
                , Cartel.Ast.ExeInfo (Cartel.Ast.GHCOptions (["-threaded"]))
                ]

-- We make the simplifying assumption that a module only appears in a
-- contiguous version range.
data PackageConstraint = PackageConstraint { packageName :: Text.Text
                                           , packageMinVersion :: [Int]
                                           , packageMaxVersion :: [Int]
                                           } deriving Generic

instance ToJSON PackageConstraint
instance FromJSON PackageConstraint

-- PackageConstraint -> Package
-- Always prefer base, otherwise arbitrarily take the first module.
constrainedPackage ps = Cartel.package (Text.unpack (packageName package)) Cartel.anyVersion
 where package = case find (\p -> packageName p == (Text.pack "base")) ps of
                   Just p' -> p'
                   Nothing -> head ps

modulePackages = foldrWithKey buildConstraints Map.empty `liftM` readHackage
 where buildConstraints name versions constraints = foldrWithKey (buildConstraints' name) constraints versions
       buildConstraints' name version meta constraints = foldr (\m cs -> Map.alter (alterConstraint (Text.pack name) (versionBranch version)) m cs) constraints (map (Text.pack . display) (exposedModules' meta))
       alterConstraint packageName' version constraint =
         case constraint of
           Nothing -> Just [PackageConstraint packageName' version version]
           Just constraints ->
             -- TODO: This could probably be more efficient.
             case find (\c -> packageName c == packageName') constraints of
               -- If the package is already listed, update the constraint.
               Just _ -> Just (map (updateConstraint packageName' version) constraints)
               -- If not, add a new constraint.
               Nothing -> Just $ constraints ++ [PackageConstraint packageName' version version]
       updateConstraint name version constraint = if packageName constraint == name
                                                    then if version < packageMinVersion constraint
                                                           then constraint { packageMinVersion = version }
                                                           else if version < packageMaxVersion constraint
                                                                  then constraint { packageMaxVersion = version }
                                                                  else constraint
                                                    else constraint
       exposedModules' = fromMaybe [] . fmap (exposedModules . condTreeData) . condLibrary

parseScript :: String -> Bool -> BS.ByteString -> Module
parseScript filename noSugar source =
  case parseFileContentsWithMode
       (defaultParseMode { parseFilename = filename
                         , extensions = exts
                         , fixities = Just (infixl_ 8 ["^..", "^?", "^?!", "^@..", "^@?", "^@?!", "^.", "^@."])})
       source' of
    ParseOk m -> m
    r@(ParseFailed _ _) -> fromParseResult r
 where exts = if noSugar then [] else [EnableExtension TemplateHaskell, EnableExtension QuasiQuotes, EnableExtension PackageImports]
       source' = if noSugar then BU.toString source'' else desugar (BU.toString source'')
       -- Remove any leading shebang line.
       source'' = if B8.isPrefixOf "#!" source
                    then B8.dropWhile (/= '\n') source
                    else source
