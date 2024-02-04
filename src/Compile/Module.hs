-----------------------------------------------------------------------------
-- Copyright 2012-2024, Microsoft Research, Daan Leijen.
--
-- This is free software; you can redistribute it and/or modify it under the
-- terms of the Apache License, Version 2.0. A copy of the License can be
-- found in the LICENSE file at the root of this distribution.
-----------------------------------------------------------------------------
{-
    Main module.
-}
-----------------------------------------------------------------------------
module Compile.Module( Module(..), ModulePhase(..)
                     , moduleNull, moduleCreateInitial
                     , modCoreImports, modImportNames

                     , Definitions(..), defsNull
                     , defsCompose, defsFromCore, defsFromModules

                     , Modules
                     , inlinesFromModules, mergeModules, mergeModulesLeftBias
                     ) where

import Lib.Trace
import Lib.PPrint
import Data.List              ( foldl' )
import Data.Char              ( isAlphaNum )
import Common.Range           ( Range, rangeNull, makeSourceRange )
import Common.Name            ( Name, ModuleName, newName, unqualify, isHiddenName, showPlain)
import Common.Error
import Common.File            ( FileTime, fileTime0, maxFileTimes, splitPath )

import Syntax.Syntax
import Syntax.Lexeme
import Syntax.RangeMap
import Type.Assumption        ( Gamma )
import qualified Core.Core as Core


import Static.FixityResolve   ( Fixities, fixitiesEmpty, fixitiesNew, fixitiesCompose )
import Kind.ImportMap
import Kind.Synonym           ( Synonyms, synonymsEmpty, synonymsCompose, extractSynonyms )
import Kind.Newtypes          ( Newtypes, newtypesEmpty, newtypesCompose, extractNewtypes )
import Kind.Constructors      ( Constructors, constructorsEmpty, constructorsCompose, extractConstructors )
import Kind.Assumption        ( KGamma, kgammaInit, extractKGamma, kgammaUnion, kgammaUnionLeftBias )

import Type.Assumption        ( Gamma, gammaInit, gammaUnion, extractGamma, gammaNames, gammaPublicNames)
import Type.Type              ( DataInfo )
import Core.Inlines           ( Inlines, inlinesNew, inlinesEmpty, inlinesExtends )
import Core.Borrowed          ( Borrowed, borrowedEmpty, extractBorrowed, borrowedCompose )
import Common.Failure (HasCallStack)


{--------------------------------------------------------------------------
  Compilation
--------------------------------------------------------------------------}
type Modules = [Module]

data ModulePhase
  = PhaseInit
  | PhaseLoaded         -- modLexemes, modDeps    (currently unused and always part of PhaseParsed)
  | PhaseParsedError
  | PhaseParsed         -- modDeps, modProgram
  | PhaseTypedError
  | PhaseTyped          -- modCore, modRangeMap, modDefines
  | PhaseOptimized      -- compiled and optimized core, modCore is updated, modInlines
  | PhaseCodeGen        -- compiled to backend code (.c,.js files)
  | PhaseLibIfaceLoaded -- a (library) interface is loaded but it's kki and libs are not yet copied to the output directory
  | PhaseLinkedError
  | PhaseLinked         -- kki and object files are generated (and exe linked for a main module)
  deriving (Eq,Ord,Show)

data Module  = Module{ -- initial
                       modPhase       :: !ModulePhase
                     , modName        :: !Name
                     , modRange       :: !Range             -- (1,1) in the source (or pre-compiled iface)
                     , modErrors      :: !Errors            -- collected errors; set for Phase<xxx>Error phases

                     , modIfacePath   :: !FilePath          -- output interface (.kki)
                     , modIfaceTime   :: !FileTime
                     , modLibIfacePath:: !FilePath          -- precompiled interface (for example for the std libs in <prefix>/lib)
                     , modLibIfaceTime:: !FileTime
                     , modSourcePath  :: !FilePath          -- can be empty for pre-compiled sources
                     , modSourceRelativePath :: !FilePath   -- for messages display a shorter path if possible
                     , modSourceTime  :: !FileTime

                       -- lexing
                     , modLexemes     :: ![Lexeme]
                     , modDeps        :: ![ModuleName]      -- initial dependencies from import statements in the program

                       -- parsing
                     , modProgram     :: !(Maybe (Program UserType UserKind))

                       -- type check; modCore is initial core that is not yet core-compiled
                     , modRangeMap    :: !(Maybe RangeMap)
                     , modCore        :: !(Maybe Core.Core)
                     , modDefinitions :: !(Maybe Definitions)

                     -- core optimized; updates `modCore` to final core
                     , modInlines     :: !(Either (Gamma -> Error () [Core.InlineDef]) [Core.InlineDef]) -- from a core file, we return a function that given the gamma parses the inlines

                       -- codegen
                     , modEntry       :: !(Maybe (FilePath,IO()))

                       -- temporary values
                     , modShouldOpen  :: !Bool
                       -- unused
                    --  , modCompiled    :: !Bool
                    --  , modTime        :: !FileTime
                     --, modPackageQName:: FilePath          -- A/B/C
                     --, modPackageLocal:: FilePath          -- lib
                     }


moduleNull :: Name -> Module
moduleNull modName
  = Module  PhaseInit modName rangeNull errorsNil
            "" fileTime0 "" fileTime0 "" "" fileTime0
            -- lex
            [] []
            -- parse
            Nothing
            -- type check
            Nothing Nothing Nothing
            -- core compiled
            (Right [])
            -- codegen
            Nothing
            -- temporary
            False

moduleCreateInitial :: Name -> FilePath -> FilePath -> FilePath -> Module
moduleCreateInitial modName sourcePath ifacePath libIfacePath
  = (moduleNull modName){ modSourcePath = sourcePath,
                          modSourceRelativePath = sourcePath,
                          modIfacePath = ifacePath,
                          modLibIfacePath = libIfacePath,
                          modRange = makeSourceRange (if null sourcePath then ifacePath else sourcePath) 1 1 1 1 }


mergeModules :: [Module] -> [Module] -> [Module]
mergeModules mods1 mods2
  = mergeModulesWith (\m1 m2 -> if modPhase m1 >= modPhase m2 then m1 else m2) mods1 mods2

mergeModulesLeftBias :: [Module] -> [Module] -> [Module]
mergeModulesLeftBias mods1 mods2
  = mergeModulesWith (\m1 m2 -> m1) mods1 mods2

mergeModulesWith :: (Module -> Module -> Module) -> [Module] -> [Module] -> [Module]
mergeModulesWith combine mods1 mods2
  = foldl' (mergeModuleWith combine) mods1 mods2

mergeModuleWith :: (Module -> Module -> Module) -> [Module] -> Module -> [Module]
mergeModuleWith combine [] mod  = [mod]
mergeModuleWith combine (m:ms) mod
  = if modName m /= modName mod
     then m : mergeModuleWith combine ms mod
     else combine m mod : ms


modCoreImports :: Module -> [Core.Import]
modCoreImports mod
  = case modCore mod of
      Nothing   -> []
      Just core -> Core.coreProgImports core


modImportNames :: Module -> [ModuleName]
modImportNames mod
  = map Core.importName (modCoreImports mod)



data Definitions  = Definitions {
                        defsGamma       :: !Gamma
                      , defsKGamma      :: !KGamma
                      , defsSynonyms    :: !Synonyms
                      , defsNewtypes    :: !Newtypes
                      , defsConstructors:: !Constructors
                      , defsFixities    :: !Fixities
                      , defsBorrowed    :: !Borrowed
                    }

defsNull :: Definitions
defsNull = Definitions gammaInit
                      kgammaInit
                      synonymsEmpty
                      newtypesEmpty
                      constructorsEmpty
                      fixitiesEmpty
                      borrowedEmpty


defsNames :: Definitions -> [Name]
defsNames defs
  = gammaNames (defsGamma defs)

defsMatchNames :: Definitions -> [String]
defsMatchNames defs
  = map (showPlain . unqualify) $ gammaPublicNames (defsGamma defs)

defsFromCore :: Bool -> Core.Core -> Definitions
defsFromCore privateAsPublic core
  = Definitions (extractGamma Core.dataInfoIsValue privateAsPublic core)
                (extractKGamma core)
                (extractSynonyms core)
                (extractNewtypes core)
                (extractConstructors core)
                (extractFixities core)
                (extractBorrowed core)
  where
    extractFixities :: Core.Core -> Fixities
    extractFixities core
      = fixitiesNew [(name,fix) | Core.FixDef name fix <- Core.coreProgFixDefs core]


defsFromModules :: HasCallStack => [Module] -> Definitions
defsFromModules mods
  = defsMerge $ map (\mod -> case modDefinitions mod of
                               Just defs | not (modShouldOpen mod) -> defs  -- cached
                               _ -> case modCore mod of
                                      Just core -> defsFromCore (modShouldOpen mod) core
                                      Nothing   -> defsNull) mods

defsMerge :: HasCallStack => [Definitions] -> Definitions
defsMerge defs  = foldl' defsCompose defsNull defs

defsCompose :: HasCallStack => Definitions -> Definitions -> Definitions
defsCompose defs1 defs2
  = Definitions (gammaUnion (defsGamma defs1) (defsGamma defs2))
                (kgammaUnionLeftBias(defsKGamma defs1) (defsKGamma defs2))
                (synonymsCompose (defsSynonyms defs1) (defsSynonyms defs2))
                (newtypesCompose (defsNewtypes defs1) (defsNewtypes defs2))
                (constructorsCompose (defsConstructors defs1) (defsConstructors defs2))
                (fixitiesCompose (defsFixities defs1) (defsFixities defs2))
                (borrowedCompose (defsBorrowed defs1) (defsBorrowed defs2))


inlinesFromModules :: [Module] -> Inlines
inlinesFromModules modules
  = inlinesExtends (concatMap inlineDefsFromModule modules) inlinesEmpty
  where
    inlineDefsFromModule mod
      = case modInlines mod of
          Right idefs -> idefs
          _           -> []      -- todo: interface files should go from typed to compiled after we resolve these
