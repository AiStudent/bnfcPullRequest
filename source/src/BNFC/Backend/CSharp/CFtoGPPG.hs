{-
    BNF Converter: C# GPPG Generator
    Copyright (C) 2006  Author:  Johan Broberg

    Modified from CFtoBisonSTL.

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, 51 Franklin Street, Fifth Floor, Boston, MA 02110-1335, USA
-}

{-
   **************************************************************
    BNF Converter Module

    Description   : This module generates the GPPG input file.

    Author        : Johan Broberg (johan@pontemonti.com)

    License       : GPL (GNU General Public License)

    Created       : 24 November, 2006

    Modified      : 17 December, 2006 by Johan Broberg

   **************************************************************
-}

{-# LANGUAGE PatternGuards #-}

module BNFC.Backend.CSharp.CFtoGPPG (cf2gppg) where

import Data.Char  (toLower)
import Data.List  (intersperse)
import Data.Maybe (fromMaybe)

import BNFC.CF
import BNFC.Backend.Common.NamedVariables hiding (varName)
import BNFC.Backend.Common.OOAbstract hiding (basetypes)
import BNFC.Backend.CSharp.CSharpUtils
import BNFC.TypeChecker
import BNFC.Utils ((+++))

--This follows the basic structure of CFtoHappy.

-- Type declarations
type Rules       = [OneRule]
type OneRule     = (NonTerminal, [(Pattern, Action)])
type Pattern     = String
type Action      = String
type MetaVar     = String

--The environment comes from the CFtoGPLEX
cf2gppg :: Namespace -> CF -> SymEnv -> String
cf2gppg namespace cf env = unlines $
  [ header namespace cf
  , union namespace $ concat $
    [ positionCats cf
    , allParserCats cf
    , map strToCat $ tokentypes $ cf2cabs cf
    ]
  , tokens (map fst $ tokenPragmas cf) env
  , declarations cf
  , ""
  , specialToks cf
  , ""
  , "%%"
  , prRules $ rulesForGPPG namespace cf env
  ]

positionCats :: CF -> [Cat]
positionCats cf = map TokenCat $ filter (isPositionCat cf) $ map fst $ tokenPragmas cf

header :: Namespace -> CF -> String
header namespace cf = unlines [
  "/* This GPPG file was machine-generated by BNFC */",
  "",
  "%namespace " ++ namespace,
  "%{",
  definedRules namespace cf,
  unlinesInline $ map (parseMethod namespace) (allParserCatsNorm cf ++ positionCats cf),
  "%}"
  ]

definedRules :: Namespace -> CF -> String
definedRules _ cf = unlinesInline [
  if null [ rule f xs e | FunDef f xs e <- cfgPragmas cf ]
    then ""
    else error "Defined rules are not yet available in C# mode!"
  ]
  where
    ctx = buildContext cf

    list = LC (const "[]") (\ t -> "List" ++ unBase t)
      where
        unBase (ListT t) = unBase t
        unBase (BaseT x) = show$normCat$strToCat x

    rule f xs e =
      case checkDefinition' list ctx f xs e of
        Left err -> error $ "Panic! This should have been caught already:\n" ++ err
        Right (_,(_,_)) -> unlinesInline [
          "Defined Rule goes here"
          ]

--This generates a parser method for each entry point.
parseMethod :: Namespace -> Cat -> String
parseMethod namespace cat = unlinesInline [
  "  " ++ returntype +++ returnvar ++ " = null;",
  "  public " ++ returntype ++ " Parse" ++ cat' ++ "()",
  "  {",
  "    if(this.Parse())",
  "    {",
  "      return " ++ returnvar ++ ";",
  "    }",
  "    else",
  "    {",
  "      throw new Exception(\"Could not parse input stream!\");",
  "    }",
  "  }",
  "  "
  ]
  where
    cat' = identCat (normCat cat)
    returntype = identifier namespace cat'
    returnvar = resultName cat'

--The union declaration is special to GPPG/GPLEX and gives the type of yylval.
--For efficiency, we may want to only include used categories here.
union :: Namespace -> [Cat] -> String
union namespace cats = unlines $ filter (\x -> x /= "\n") [
  "%union",
  "{",
  "  public int int_;",
  "  public char char_;",
  "  public double double_;",
  "  public string string_;",
  unlinesInline $ map catline cats,
  "}"
  ]
  where --This is a little weird because people can make [Exp2] etc.
    catline cat | (identCat cat /= show cat) || ((normCat cat) == cat) =
      "  public " ++ identifier namespace (identCat (normCat cat)) +++ (varName (show$normCat cat)) ++ ";"
    catline _ = ""

-- | Declares non-terminal types.
declarations :: CF -> String
declarations cf = unlinesInline $ map typeNT $
  positionCats cf ++
  filter (not . null . rulesForCat cf) (allParserCats cf)  -- don't define internal rules
  where
  typeNT nt = "%type <" ++ varName x ++ "> " ++ x
    where x = show $ normCat nt

--declares terminal types.
tokens :: [UserDef] -> SymEnv -> String
tokens user ts = concatMap declTok ts
  where
    declTok (s, r) = if s `elem` user
      then "%token<" ++ varName (show$normCat$strToCat s) ++ "> " ++ r ++ "   //   " ++ s ++ "\n"
      else "%token " ++ r ++ "    //   " ++ s ++ "\n"

specialToks :: CF -> String
specialToks cf = unlinesInline [
  ifC catString  "%token<string_> STRING_",
  ifC catChar    "%token<char_> CHAR_",
  ifC catInteger "%token<int_> INTEGER_",
  ifC catDouble  "%token<double_> DOUBLE_",
  ifC catIdent   "%token<string_> IDENT_"
  ]
  where
    ifC cat s = if isUsedCat cf (TokenCat cat) then s else ""

--The following functions are a (relatively) straightforward translation
--of the ones in CFtoHappy.hs
rulesForGPPG :: Namespace -> CF -> SymEnv -> Rules
rulesForGPPG namespace cf env = (map mkOne $ ruleGroups cf) ++ posRules where
  mkOne (cat,rules) = constructRule namespace cf env rules cat
  posRules = map mkPos $ positionCats cf
  mkPos :: Cat -> OneRule
  mkPos cat = (cat, [(fromMaybe s $ lookup s env, "$$ = new " ++ s ++ "($1);")])
    where s = show cat

-- | For every non-terminal, we construct a set of rules.
constructRule :: Namespace ->
  CF -> SymEnv -> [Rule] -> NonTerminal -> (NonTerminal,[(Pattern,Action)])
constructRule namespace cf env rules nt =
  (nt,[(p,(generateAction namespace nt (ruleName r) b m) +++ result) |
     r0 <- rules,
     let (b,r) = if isConsFun (funRule r0) && elem (valCat r0) revs
                   then (True,revSepListRule r0)
                 else (False,r0),
     let (p,m) = generatePatterns cf env r b])
  where
    ruleName r = case funRule r of
      ---- "(:)" -> identCat nt
      ---- "(:[])" -> identCat nt
      z -> z
    revs = cfgReversibleCats cf
    eps = allEntryPoints cf
    isEntry nt = if elem nt eps then True else False
    result = if isEntry nt then (resultName (identCat (normCat nt))) ++ "= $$;" else ""

-- Generates a string containing the semantic action.
-- This was copied from CFtoCup15, with only a few small modifications
generateAction :: Namespace -> NonTerminal -> Fun -> Bool -> [(MetaVar, Bool)]
               -> Action
generateAction namespace nt f rev mbs
  | isNilFun f             = "$$ = new " ++ identifier namespace c ++ "();"
  | isOneFun f             = "$$ = new " ++ identifier namespace c ++ "(); $$.Add(" ++ p_1 ++ ");"
  | isConsFun f && not rev = "$$ = " ++ p_2 ++ "; " ++ p_2 ++ ".Insert(0, " ++ p_1 ++ ");"
  | isConsFun f && rev     = "$$ = " ++ p_1 ++ "; " ++ p_1 ++ ".Add(" ++ p_2 ++ ");"
  | isCoercion f           = "$$ = " ++ p_1 ++ ";"
  | isDefinedRule f        = "$$ = " ++ f ++ "_" ++ "(" ++ concat (intersperse "," ms) ++ ");"
  | otherwise              = "$$ = new " ++ identifier namespace c ++ "(" ++ concat (intersperse "," ms) ++ ");"
  where
    c = if isNilFun f || isOneFun f || isConsFun f
        then identCat (normCat nt) else f
    ms = map fst mbs
    p_1 = ms!!0
    p_2 = ms!!1


-- Generate patterns and a set of metavariables indicating
-- where in the pattern the non-terminal
generatePatterns :: CF -> SymEnv -> Rule -> Bool -> (Pattern,[(MetaVar,Bool)])
generatePatterns cf env r _ = case rhsRule r of
  []  -> ("/* empty */",[])
  its -> (unwords (map mkIt its), metas its)
    where
    mkIt = \case
      Left c
          | TokenCat tok <- c, isPositionCat cf tok -> fallback
          | show c `elem` map fst basetypes         -> fallback
          | otherwise                               -> fromMaybe fallback $ lookup (show c) env
        -- This used to be x, but that didn't work if we had a symbol "String" in env, and tried to use a normal String - it would use the symbol...        _ -> fallback
        where fallback = typeName (identCat c)
      Right s -> fromMaybe s $ lookup s env
    metas its = [('$': show i,revert c) | (i,Left c) <- zip [1 :: Int ..] its]

    -- notice: reversibility with push_back vectors is the opposite
    -- of right-recursive lists!
    revert c = (isList c) &&
               not (isConsFun (funRule r)) && notElem c revs
    revs = cfgReversibleCats cf

-- We have now constructed the patterns and actions,
-- so the only thing left is to merge them into one string.

prRules :: Rules -> String
prRules [] = []
prRules ((_, []):rs) = prRules rs --internal rule
prRules ((nt,(p,a):ls):rs) =
  (unwords [nt', ":" , p, "{ ", a, "}", "\n" ++ pr ls]) ++ ";\n" ++ prRules rs
  where
    nt' = identCat nt
    pr []           = []
    pr ((p,a):ls)   = (unlines [(concat $ intersperse " " ["  |", p, "{ ", a , "}"])]) ++ pr ls

--Some helper functions.
resultName :: String -> String
resultName s = "YY_RESULT_" ++ s ++ "_"

--slightly stronger than the NamedVariable version.
varName :: String -> String
varName s = (map toLower (identCat $ strToCat s)) ++ "_"

typeName :: String -> String
typeName "Ident" = "IDENT_"
typeName "String" = "STRING_"
typeName "Char" = "CHAR_"
typeName "Integer" = "INTEGER_"
typeName "Double" = "DOUBLE_"
typeName x = x
