-----------------------------------------------------------------------------
-- Copyright 2012-2024, Microsoft Research, Daan Leijen.
--
-- This is free software; you can redistribute it and/or modify it under the
-- terms of the Apache License, Version 2.0. A copy of the License can be
-- found in the LICENSE file at the root of this distribution.
-----------------------------------------------------------------------------
module Compile.BuildContext ( BuildContext
                            , buildcEmpty

                            , buildcTypeCheck, buildcBuild
                            , buildcValidate
                            , buildcBuildEx

                            , buildcRunExpr, buildcRunEntry
                            , buildcCompileExpr, buildcCompileEntry

                            , buildcAddRootSources
                            , buildcAddRootModules
                            , buildcRoots
                            , buildcClearRoots, buildcRemoveRootModule, buildcRemoveRootSource
                            , buildcFocus

                            , buildcLookupModuleName
                            , buildcGetDefinitions
                            , buildcGetMatchNames
                            , buildcLookupTypeOf
                            , buildcLookupInfo
                            , buildcOutputDir
                            , buildcSearchSourceFile
                            , buildcGetMainEntry
                            , buildcThrowOnError
                            , buildcTermInfo
                            , buildcFlags

                            , runBuildIO, runBuildMaybe, runBuild, addErrorMessageKind
                            , buildLiftIO

                            , Definitions(..), Build
                            , VFS(..), withVFS, noVFS
                            ) where


import Debug.Trace
import Data.List
import Control.Monad( when )
import qualified Data.Map.Strict as M
import Platform.Config
import Lib.PPrint
import Common.Name
import Common.NamePrim (nameSystemCore, nameTpNamed, nameTpAsync, isSystemCoreName)
import Common.Range
import Common.File
import Common.Error
import Common.Failure
import Common.ColorScheme
import Type.Type
import qualified Type.Pretty as TP
import Type.Kind       (extractHandledEffect, getHandledEffectX )
import Type.Assumption
import Compile.Options
import Compile.Module
import Compile.Build
import Compiler.Compile (searchSource)



-- An abstract build context contains all information to build
-- from a set of root modules (open files in an IDE, compilation files on a command line)
-- It checks it validity against the flags it was created from.
data BuildContext = BuildContext {
                      buildcRoots   :: ![ModuleName],
                      buildcModules :: ![Module],
                      buildcHash    :: !String
                    }

-- An empty build context
buildcEmpty :: Flags -> BuildContext
buildcEmpty flags
  = BuildContext [] [] $! flagsHash flags


-- Add roots to a build context
buildcAddRootSources :: [FilePath] -> BuildContext -> Build (BuildContext,[ModuleName])
buildcAddRootSources fpaths buildc
  = do mods <- mapM moduleFromSource fpaths
       let rootNames = map modName mods
           roots   = nub (map modName mods ++ buildcRoots buildc)
           modules = mergeModules mods (buildcModules buildc)
       seqList roots $ seqList modules $
        return (buildc{ buildcRoots = roots, buildcModules = modules }, rootNames)

-- Add root modules (by module name) to a build context
buildcAddRootModules :: [ModuleName] -> BuildContext -> Build BuildContext
buildcAddRootModules moduleNames buildc
  = do mods <- mapM (moduleFromModuleName "" {-relative dir-}) moduleNames
       let roots   = nub (map modName mods ++ buildcRoots buildc)
           modules = mergeModules mods (buildcModules buildc)
       seqList roots $ seqList modules $
        return buildc{ buildcRoots = roots, buildcModules = modules }

-- Clear the roots
buildcClearRoots :: BuildContext -> BuildContext
buildcClearRoots buildc
  = buildc{ buildcRoots = [] }

-- Remove a root module
buildcRemoveRootModule :: ModuleName -> BuildContext -> BuildContext
buildcRemoveRootModule mname buildc
  = buildc{ buildcRoots = filter (/=mname) (buildcRoots buildc) }

-- Lookup the module name for a module source previously added.
buildcLookupModuleName :: FilePath -> BuildContext -> Maybe ModuleName
buildcLookupModuleName fpath0 buildc
  = let fpath = normalize fpath0
    in modName <$> find (\m -> modSourcePath m == fpath || modSourceRelativePath m == fpath) (buildcModules buildc)

-- Remove a root by file name
buildcRemoveRootSource :: FilePath -> BuildContext -> BuildContext
buildcRemoveRootSource fpath buildc
  = case buildcLookupModuleName fpath buildc of
      Just mname -> buildcRemoveRootModule mname buildc
      _          -> buildc

-- After a type check, the definitions (gamma, kgamma etc.) can be returned
-- for a given set of modules.
buildcGetDefinitions :: [ModuleName] -> BuildContext -> Definitions
buildcGetDefinitions modules0 buildc
  = let modules = if null modules0 then buildcRoots buildc else modules0
    in defsFromModules (filter (\mod -> modName mod `elem` modules) (buildcModules buildc))


-- After a type check, return all visible values for a set of modules.
-- Used for completion in the interpreter for example
buildcGetMatchNames :: [ModuleName] -> BuildContext -> [String]
buildcGetMatchNames modules buildc
  = let defs = buildcGetDefinitions modules buildc
    in map (showPlain . unqualify) $ gammaPublicNames (defsGamma defs)


-- Focus a build action on a restricted context with the given focus roots.
-- This builds only modules needed for the restricted roots, but keeps all cached modules and original roots.
-- Returns also a list of all touched modules in the restricted build (for diagnostics)
buildcFocus :: [ModuleName] -> BuildContext -> (BuildContext -> Build (BuildContext, a)) -> Build (BuildContext, a, [ModuleName])
buildcFocus focusRoots buildc0 action
  = do buildcFull <- buildcAddRootModules focusRoots buildc0
       let roots   = buildcRoots buildcFull
           cached  = buildcModules buildcFull
           buildcF = buildcFull{ buildcRoots = focusRoots }
       buildcFocus <- buildcValidate False [] buildcF
       (buildcRes,x) <- action buildcFocus
       let touched = map modName (buildcModules buildcRes)
           mmods   = mergeModules (buildcModules buildcRes) cached
       seqList touched $ seqList mmods $
         do let buildcFullRes = buildcRes{ buildcRoots = roots, buildcModules = mmods }
            return (buildcFullRes, x, touched)


-- Reset a build context from the roots (for example, when the flags have changed)
buildcFreshFromRoots :: BuildContext -> Build BuildContext
buildcFreshFromRoots buildc
  = do let (roots,imports) = buildcSplitRoots buildc
           rootSources = map modSourcePath roots
       flags <- getFlags
       (buildc1,_) <- buildcAddRootSources rootSources (buildc{ buildcRoots = [], buildcModules=[], buildcHash = flagsHash flags })
       let (roots1,_) = buildcSplitRoots buildc1
       mods  <- modulesReValidate False [] [] roots1
       return buildc1{ buildcModules = mods }

-- Check if the flags are still valid for this context
buildcValidateFlags :: BuildContext -> Build BuildContext
buildcValidateFlags buildc
  = do flags <- getFlags
       let hash = flagsHash flags
       if (hash == buildcHash buildc)
        then return buildc
        else buildcFreshFromRoots buildc

-- Validate a build context to the current state of the file system and flags,
-- and resolve any required modules to build the root set. Also discards
-- any cached modules that are no longer needed.
-- Can pass a boolean to force everything to be rebuild (on a next build)
-- or a list of specific modules to be recompiled.
buildcValidate :: Bool -> [ModuleName] -> BuildContext -> Build BuildContext
buildcValidate rebuild forced buildc
  = do flags <- getFlags
       let hash = flagsHash flags
       if (hash /= buildcHash buildc)
         then buildcFreshFromRoots buildc
         else do let (roots,imports) = buildcSplitRoots buildc
                 mods <- modulesReValidate rebuild forced imports roots
                 return buildc{ buildcModules = mods }

-- Return the root modules and their (currently cached) dependencies.
buildcSplitRoots :: BuildContext -> ([Module],[Module])
buildcSplitRoots buildc
  = partition (\m -> modName m `elem` buildcRoots buildc) (buildcModules buildc)


-- Type check the current build context (also validates and resolves)
buildcTypeCheck :: BuildContext -> Build BuildContext
buildcTypeCheck buildc0
  = do buildc <- buildcValidate False [] buildc0
       mods   <- modulesTypeCheck (buildcModules buildc)
       return buildc{ buildcModules = mods }

-- Build the current build context under a given set of main entry points. (also validates)
buildcBuild :: [Name] -> BuildContext -> Build BuildContext
buildcBuild mainEntries buildc
  = buildcBuildEx False [] mainEntries buildc

-- Build the current build context under a given set of main entry points. (also validates)
-- Can pass a flag to force a rebuild of everything, or a recompile of specific modules.
buildcBuildEx :: Bool -> [ModuleName] -> [Name] -> BuildContext -> Build BuildContext
buildcBuildEx rebuild forced mainEntries buildc0
  = phaseTimed 2 "building" (\penv -> empty) $
    do buildc <- buildcValidate rebuild forced buildc0
       mods <- modulesBuild mainEntries (buildcModules buildc)
       return (buildc{ buildcModules = mods})

-- After a build with given main entry points, return a compiled entry
-- point for a given module as the executable path, and an `IO` action
-- that runs the program (using `node` for a node backend, or `wasmtime` for wasm etc.).
buildcGetMainEntry :: ModuleName -> BuildContext -> Maybe (FilePath,IO ())
buildcGetMainEntry modname buildc
  = case find (\mod -> modName mod == modname) (buildcModules buildc) of
      Just mod -> modEntry mod
      _        -> Nothing

-- Build and run a specific main-like entry function, called as `<name>()`
buildcRunEntry :: Name -> BuildContext -> Build BuildContext
buildcRunEntry name buildc
  = buildcRunExpr [qualifier name] (show name ++ "()") buildc

-- Build and run an expression with functions visible in the given module names (including private definitions).
-- Used from the interpreter and IDE.
buildcRunExpr :: [ModuleName] -> String -> BuildContext -> Build BuildContext
buildcRunExpr importNames expr buildc
  = do (buildc1,mbTpEntry) <- buildcCompileExpr True False importNames expr buildc
       case mbTpEntry of
          Just(_,Just (_,run))
            -> do phase "" (\penv -> empty)
                  liftIO $ run
          _ -> return ()
       return buildc1

-- Compile a function call (called as `<name>()`) and return its type and possible entry point (if `typeCheckOnly` is `False`)
buildcCompileEntry :: Bool -> Name -> BuildContext -> Build (BuildContext,Maybe (Type, Maybe (FilePath,IO ())))
buildcCompileEntry typeCheckOnly name buildc
  = buildcCompileExpr False typeCheckOnly [qualifier name] (show name ++ "()") buildc

-- Compile an expression with functions visible in the given module names (including private definitions),
-- and return its type and possible entry point (if `typeCheckOnly` is `False`).
buildcCompileExpr :: Bool -> Bool -> [ModuleName] -> String -> BuildContext -> Build (BuildContext, Maybe (Type, Maybe (FilePath,IO ())))
buildcCompileExpr addShow typeCheckOnly importNames0 expr buildc
  = phaseTimed 2 "compile" (\penv -> empty) $
    do let importNames = if null importNames0 then buildcRoots buildc else importNames0
           sourcePath = joinPaths [
                          virtualMount,
                          case [modSourceRelativePath mod | mname <- importNames,
                                                   mod <- case find (\mod -> modName mod == mname) (buildcModules buildc) of
                                                            Just m  -> [m]
                                                            Nothing -> []] of
                              (fpath:_) -> noexts fpath
                              _         -> "",
                          "@main" ++ sourceExtension]
           importDecls = map (\mname -> "@open import " ++ show mname) importNames
           content     = bunlines $ importDecls ++ [
                           "pub fun @expr()",
                           "#line 1",
                           "  " ++ expr
                         ]

       withVirtualModule sourcePath content buildc $ \mainModName buildc1 ->
         do -- type check first
            let exprName = qualify mainModName (newName "@expr")
            buildc2 <- buildcTypeCheck buildc1
            mbRng   <- hasBuildError
            case mbRng of
              Just rng -> do when (addShow || typeCheckOnly) $ showMarker rng
                             return (buildc2,Nothing)
              Nothing  -> case buildcLookupTypeOf exprName buildc2 of
                            Nothing -> do addErrorMessageKind ErrBuild (\penv -> text "unable to resolve the type of the expression" <+> parens (TP.ppName penv exprName))
                                          return (buildc2, Nothing)
                            Just tp -> if typeCheckOnly
                                        then return (buildc2,Just (tp,Nothing))
                                        else buildcCompileMainBody addShow expr importDecls sourcePath mainModName exprName tp buildc2

buildcCompileMainBody :: Bool -> String -> [String] -> FilePath -> Name -> Name -> Type -> BuildContext -> Build (BuildContext,Maybe (Type, Maybe (FilePath,IO ())))
buildcCompileMainBody addShow expr importDecls sourcePath mainModName exprName tp buildc1
  = do  -- then compile with a main function
        (tp,showIt,mainBody) <- completeMain True exprName tp buildc1
        let mainName = qualify mainModName (newName "@main")
            mainDef  = bunlines $ importDecls ++ [
                        "pub fun @expr() : _ ()",
                        "#line 1",
                        "  " ++ showIt expr,
                        "",
                        "pub fun @main() : io ()",
                        "  " ++ mainBody,
                        ""
                        ]
        withVirtualFile sourcePath mainDef $ \_ ->
           do buildc2 <- buildcBuild [mainName] buildc1
              mbRng   <- hasBuildError
              case mbRng of
                Just rng -> do when addShow $ showMarker rng
                               return (buildc2,Nothing)
                _        -> do -- and return the entry point
                               let mainMod = buildcFindModule mainModName buildc2
                                   entry   = modEntry mainMod
                               return $ seq entry (buildc2,Just(tp,entry))

-- Show a marker in the interpreter
showMarker :: Range -> Build ()
showMarker rng
  = do let c1 = posColumn (rangeStart rng)
           c2 = if (posLine (rangeStart rng) == posLine (rangeStart rng))
                 then posColumn (rangeEnd rng)
                else c1
       cscheme <- getColorScheme
       term    <- getTerminal
       let doc = color (colorMarker cscheme) (text (replicate (c1 - 1) ' ' ++ replicate 1 {- (c2 - c1 + 1) -} '^'))
       liftIO $ termInfo term doc


bunlines :: [String] -> BString
bunlines xs = stringToBString $ unlines xs

-- complete a main function by adding a show function (if `addShow` is `True`), and
-- adding any required rdefault effect handlers (for async, utc etc.)
completeMain :: Bool -> Name -> Type -> BuildContext -> Build (Type,String -> String,String)
completeMain addShow exprName tp buildc
  = case splitFunScheme tp of
      Just (_,_,_,eff,resTp)
        -> let (ls,_) = extractHandledEffect eff
           in do print    <- printExpr resTp
                 mainBody <- addDefaultHandlers rangeNull eff ls callExpr
                 return (resTp,print,mainBody)
      _ -> return (tp, id, callExpr) -- todo: given an error?
  where
    callExpr
      = show exprName ++ "()"

    printExpr resTp
      = if isTypeUnit resTp || not addShow
          then return id
          else case expandSyn resTp of
                 TFun _ _ _ -> return (\expr -> "println(\"<function>\")")
                 _          -> return (\expr -> "(" ++ expr ++ ").println")

    exclude = [nameTpNamed] -- nameTpCps,nameTpAsync

    addDefaultHandlers :: Range -> Effect -> [Effect] -> String -> Build String
    addDefaultHandlers range eff [] body     = return body
    addDefaultHandlers range eff (l:ls) body
      = case getHandledEffectX exclude l of
          Nothing -> addDefaultHandlers range eff ls body
          Just (_,effName)
            -> let defaultHandlerName
                      = makeHiddenName "default" (if isSystemCoreName effName
                                                    then qualify nameSystemCore (unqualify effName) -- std/core/* defaults must be in std/core
                                                    else effName) -- and all others in the same module as the effect
              in case buildcLookupInfo defaultHandlerName buildc of
                    [fun@InfoFun{}]
                      -> do phaseVerbose 2 "main" $ \penv -> text "add default effect for" <+> TP.ppName penv effName
                            let handle b = show defaultHandlerName ++ "(fn() " ++ b ++ ")"
                            if (effName == nameTpAsync)  -- always put async as the most outer effect
                              then do body' <- addDefaultHandlers range eff ls body
                                      return (handle body')
                              else addDefaultHandlers range eff ls (handle body)
                    infos
                      -> do throwError (\penv -> errorMessageKind ErrBuild range
                                           (text "there are unhandled effects for the main expression" <-->
                                            text " inferred effect :" <+> TP.ppType penv eff <-->
                                            text " unhandled effect:" <+> TP.ppType penv l <-->
                                            text " hint            : wrap the main function in a handler"))
                            addDefaultHandlers range eff ls body


-- Run a build action with a virtual module that is added to the roots.
withVirtualModule :: FilePath -> BString -> BuildContext -> (ModuleName -> BuildContext -> Build (BuildContext,a)) -> Build (BuildContext,a)
withVirtualModule fpath0 content buildc action
  = withVirtualFile fpath0 content $ \fpath ->
    do (buildc1,[modName]) <- buildcAddRootSources [fpath] buildc
       (buildc2,x) <- action modName buildc1
       return (buildcRemoveRootSource fpath buildc2, x)

-- Run a build action with a virtual file.
withVirtualFile :: FilePath -> BString -> (FilePath -> Build a) -> Build a
withVirtualFile fpath0 content action
  = do ftime <- liftIO $ getCurrentTime
       let fpath = normalize fpath0
           vfs   = VFS (\fname -> if fname == fpath then Just (content,ftime) else Nothing)
       phaseVerbose 2 "trace" (\penv -> text "add virtual file" <+> text fpath <+> text ", content:" <-> text (bstringToString content))
       withVFS vfs $ action fpath

-- Return a module by name
buildcFindModule :: HasCallStack => ModuleName -> BuildContext -> Module
buildcFindModule modname buildc
  = case find (\mod -> modName mod == modname) (buildcModules buildc) of
      Just mod -> mod
      _        -> failure ("Compile.BuildIde.btxFindModule: cannot find " ++ show modname ++ " in " ++ show (map modName (buildcModules buildc)))

-- Lookup `NameInfo` in a build context from a fully qualified name
buildcLookupInfo :: Name -> BuildContext -> [NameInfo]
buildcLookupInfo name buildc
  = case find (\mod -> modName mod == qualifier name) (buildcModules buildc) of
      Just mod -> -- trace ("lookup " ++ show name ++ " in " ++ show (modName mod) ++ "\n" ++ showHidden (defsGamma (defsFromModules [mod]))) $
                  map snd (gammaLookup name (defsGamma (defsFromModules [mod])))
      _        -> []

-- Lookup the type of a fully qualified name
buildcLookupTypeOf :: Name -> BuildContext -> Maybe Type
buildcLookupTypeOf name buildc
  = case buildcLookupInfo name buildc of
      [info] | isInfoValFunExt info -> Just (infoType info)
      _      -> Nothing

-- Return the current output directory
buildcOutputDir :: Build FilePath
buildcOutputDir
  = do flags <- getFlags
       return (outName flags "")

-- Search for a search file according to the include paths and virtual files.
-- Returns the root of the path and the maximal stem according to the include path.
buildcSearchSourceFile :: FilePath -> BuildContext -> Build (Maybe (FilePath,FilePath))
buildcSearchSourceFile fpath buildc
  = searchSourceFile "" fpath

-- Throw if any error with severity `SevError` or higher has happened
buildcThrowOnError :: Build ()
buildcThrowOnError
  = throwOnError

-- Send a message to the terminal
buildcTermInfo :: (TP.Env -> Doc) -> Build ()
buildcTermInfo mkDoc
  = do term <- getTerminal
       penv <- getPrettyEnv
       liftIO $ termInfo term (mkDoc penv)

-- Get the current flags
buildcFlags :: Build Flags
buildcFlags
  = getFlags

-- Lift an IO operation.
buildLiftIO :: IO a -> Build a
buildLiftIO
  = liftIO
