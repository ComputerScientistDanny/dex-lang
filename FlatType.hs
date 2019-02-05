module FlatType (exprToVal, cmdToVal, flattenType, unflattenType, flattenVal,
                 unflattenVal, showVal, parseVal, PrintSpec, defaultPrintSpec,
                 TabType) where

import Data.List (intercalate, transpose)
import Data.Monoid ((<>))
import Control.Monad (void, liftM)
import Text.Megaparsec
import Text.Megaparsec.Char hiding (space)
import qualified Text.Megaparsec.Char.Lexer as L

import Record
import Util
import ParseUtil
import Env
import qualified Data.Map.Strict as M
import qualified Typer as T
import qualified Syntax as S
import qualified Interpreter as I
import Data.List (foldr1, intersperse)

type TabName = [RecName]
data ScalarType = BaseType S.BaseType
                | UnitType  deriving (Eq, Show)
type FlatTree a = [([RecName], a)]
type Scalars = FlatTree ScalarType
data TabType = TabType TabName Scalars TabType
             | ValPart Scalars
                 deriving (Eq, Show)
type TypedExpr = (S.SigmaType, S.Expr)

-- this is here rather than in Interpreter for as a circular import workaround
exprToVal :: TypedExpr -> S.FullEnv I.TypedVal () () -> S.Except (I.TypedVal, ())
exprToVal (t, expr) env =
    let ans = I.evalExpr expr (fmap stripType (S.lEnv env))
    in Right (I.TypedVal t ans, ())

cmdToVal :: S.Command TypedExpr -> S.FullEnv I.TypedVal () () -> S.Command ()
cmdToVal (S.Command cmd (t, expr)) env =
  case cmd of
    S.EvalExpr -> let v = I.evalExpr expr (fmap stripType (S.lEnv env))
                  in case showVal defaultPrintSpec t v of
                       Left e  -> S.CmdErr e
                       Right s -> S.CmdResult s
cmdToVal (S.CmdResult s) _ = S.CmdResult s
cmdToVal (S.CmdErr e)    _ = S.CmdErr e

stripType :: I.TypedVal -> I.Val
stripType (I.TypedVal t v) = v


flatLeaf :: a -> FlatTree a
flatLeaf x = [([], x)]

flatTree :: [(RecName, FlatTree a)] -> FlatTree a
flatTree namedTrees = [(name:names, v) | (name,  tree) <- namedTrees
                                       , (names, v) <- tree]

unFlatTree :: FlatTree a -> [(RecName, FlatTree a)]
unFlatTree t = group $ [(k, (ks, v)) | (k:ks, v) <- t]

unFlatTreeRec :: (a -> b) -> (Record b -> b) -> FlatTree a -> b
unFlatTreeRec leafFun nodeFun t = case t of
  [([], v)] -> leafFun v
  xs -> nodeFun . recFromList . mapSnd recurse . unFlatTree $ xs
  where recurse = unFlatTreeRec leafFun nodeFun

checkType :: S.Type -> S.Except ()
checkType t = case t of
   S.TabType a b -> checkType a >> checkType b
   S.RecType r -> sequence (fmap checkType r) >> return ()
   S.BaseType b -> Right ()
   _ -> Left $ S.PrintErr $ "Can't print value with type " ++ show t

flattenType :: S.Type -> S.Except [TabType]
flattenType t = checkType t >> (return $ flattenTypeRec t)

flattenTypeRec :: S.Type -> [TabType]
flattenTypeRec t = case t of
   S.TabType a b -> let leftKeys = flattenIdxType a
                        rightTabs = flattenTypeRec b
                    in map (TabType [] leftKeys) rightTabs
   S.RecType r | isEmpty r -> [ValPart (flatLeaf UnitType)]
               | otherwise -> let
                   ts = [(k,t) | (k, ts) <- recToList $ fmap flattenTypeRec r
                               , t <- ts]
                   nonValTabs = [TabType (k:name) s rest
                                  | (k, TabType name s rest) <- ts]
                 in case [(k, s) | (k, ValPart s) <- ts] of
                      [] -> nonValTabs
                      vs -> (ValPart $ flatTree vs) : nonValTabs
   S.BaseType b -> [ValPart (flatLeaf $ BaseType b)]

flattenIdxType :: S.Type -> Scalars
flattenIdxType t = case t of
   S.RecType r | isEmpty r -> flatLeaf UnitType
               | otherwise -> flatTree . recToList $ fmap flattenIdxType r
   S.BaseType b -> flatLeaf (BaseType b)

unflattenType :: [TabType] -> S.Type
unflattenType tabs = foldr1 mergeTypes (map unflattenTab tabs)

unflattenTab :: TabType -> S.Type
unflattenTab tab = case tab of
    ValPart s -> scalarType s
    TabType name s rest -> let t = S.TabType (scalarType s) (unflattenTab rest)
                            in recFromName S.RecType name t
  where scalarType = unFlatTreeRec scalarTypeToType S.RecType

scalarTypeToType :: ScalarType -> S.Type
scalarTypeToType s = case s of BaseType b -> S.BaseType b
                               UnitType   -> S.RecType emptyRecord

mergeTypes :: S.Type -> S.Type -> S.Type
mergeTypes (S.RecType r1) (S.RecType r2) =
  S.RecType $ recUnionWith mergeTypes r1 r2
mergeTypes (S.TabType a1 b1) (S.TabType a2 b2) | a1 == a2 =
  S.TabType a1 (mergeTypes b1 b2)

----- flattening vals -----

type ColName = [RecName]
data ScalarVal = IntVal Int
               | BoolVal Bool
               | RealVal Float
               | StrVal String
               | AnyVal
               | UnitVal  deriving (Ord, Eq, Show)

type Row = [ScalarVal]
type TabVal = [Row]

flattenVal :: I.Val -> [TabType] -> [TabVal]
flattenVal v ts = map (getRows v) ts

unflattenVal :: [TabVal] -> [TabType] -> I.Val
unflattenVal rows ts = foldr1 mergeVals (zipWith unflattenRows rows ts)

getColTypes :: TabType -> [ScalarType]
getColTypes t = case t of
    ValPart s -> getTypes s
    TabType name s rest -> getTypes s ++ getColTypes rest
  where
    getTypes s = map snd s

getRows :: I.Val -> TabType -> TabVal
getRows v t = case t of
  ValPart s -> [flattenScalarTree v s]
  TabType name s rest ->
    let I.TabVal m = lookupPath v name
    in concat [catRows (flattenScalarTree k s) (getRows v' rest)
                | (k,v') <- M.toList m ]

catRows :: Monoid a => a -> [a] -> [a]
catRows x [] = [x]
catRows x xs = map (x <>) xs

flattenScalarTree :: I.Val -> Scalars -> [ScalarVal]
flattenScalarTree v s = map (valToScalarVal . lookupPath v) (map fst s)

valToScalarVal :: I.Val -> ScalarVal
valToScalarVal v = case v of
  I.IntVal  x -> IntVal  x ; I.BoolVal x -> BoolVal x
  I.RealVal x -> RealVal x ; I.StrVal  x -> StrVal  x
  I.RecVal r | isEmpty r -> UnitVal
  I.Any -> AnyVal

scalarValToVal :: ScalarVal -> I.Val
scalarValToVal v = case v of
  IntVal  x -> I.IntVal  x ; BoolVal x -> I.BoolVal x
  RealVal x -> I.RealVal x ; StrVal  x -> I.StrVal  x
  UnitVal -> I.RecVal emptyRecord

unflattenRows :: [[ScalarVal]] -> TabType -> I.Val
unflattenRows rows (TabType tabname s rest) = recFromName I.RecVal tabname tab
  where
    tab = I.TabVal $
      case rows of
        [[]]  -> M.empty
        rows' -> let numCols = length (map fst s)
                     groupedRows = group . map (splitAt numCols) $ rows'
                 in M.fromList [(unflattenRow k s, unflattenRows v rest)
                                | (k, v) <- groupedRows]
unflattenRows [row] (ValPart s) = unflattenRow row s

unflattenRow :: [ScalarVal] -> Scalars -> I.Val
unflattenRow vals s =
  let names = map fst s
      vals' = map scalarValToVal vals
  in foldr1 mergeVals $ zipWith (recFromName I.RecVal) names vals'

mergeVals :: I.Val -> I.Val -> I.Val
mergeVals (I.RecVal r1) (I.RecVal r2) =
  I.RecVal $ recUnionWith mergeVals r1 r2
mergeVals (I.TabVal m1) (I.TabVal m2) | M.keys m1 == M.keys m1 =
  I.TabVal $ M.intersectionWith mergeVals m1 m2
mergeVals v1 v2 = error ("Can't merge " ++ show v1 ++ " and " ++ show v2)

lookupPath :: I.Val -> [RecName] -> I.Val
lookupPath v [] = v
lookupPath (I.RecVal r) (name:rest) = let Just v = recLookup name r
                                       in lookupPath v rest

-- ----- printing -----

data PrintSpec = PrintSpec { manualAlign :: Bool }

defaultPrintSpec = PrintSpec True

showVal :: PrintSpec -> S.SigmaType -> I.Val -> S.Except String
showVal ps (S.Forall _ t) v = do
  tabTypes <- flattenType t
  let tabVals = flattenVal v tabTypes
  return . intercalate "\n" $ zipWith (printTab ps) tabTypes tabVals

printTab :: PrintSpec -> TabType -> TabVal -> String
printTab ps t v =
  printTabName t ++ (alignCells ps $ printHeader t : map (map printScalar) v)

alignCells :: PrintSpec -> [[String]] -> String
alignCells ps rows = unlines $ if manualAlign ps
  then let colLengths = map maxLength (transpose rows)
           rows' = map padRow rows
           padRow = zipWith (padLeft ' ') colLengths
       in map (intercalate " ") rows'
  else map (intercalate "\t") rows

maxLength :: [String] -> Int
maxLength = foldr (\x y -> max (length x) y) 0

printTabName :: TabType -> String
printTabName t = case getTabName t of
  names | length (concat names) == 0 -> ""
        | otherwise -> "> " ++ (intercalate " | " $ map printName names) ++ "\n"

getTabName :: TabType -> [[RecName]]
getTabName (TabType name _ rest) = name : getTabName rest
getTabName (ValPart _) = []

printHeader :: TabType -> [String]
printHeader (TabType _ s rest) = printTreeList s ++ printHeader rest
printHeader (ValPart s) = printTreeList s

printTreeList :: Scalars -> [String]
printTreeList = splitOn ('\t' ==) . printTree

printTree :: Scalars -> String
printTree [([], v)] = case v of UnitType -> "()"
                                BaseType x -> show x
printTree s = let (ks, vs) = unzip $ unFlatTree s
                  spec = RecordPrintSpec "\t" ":" "" (Just ks)
                  r = recFromList $ zip ks vs
              in printRecord printTree spec r

printName :: [RecName] -> String
printName names = concat $ intersperse "." (map show names)

printScalar :: ScalarVal -> String
printScalar v = case v of
  IntVal  x -> show x ; BoolVal x -> show x
  RealVal x -> show x ; StrVal  x -> show x
  UnitVal -> "()"
  AnyVal -> "*"

-- ----- parsing -----

parseVal :: String -> S.Except (S.Type, I.Val)
parseVal s = case parse topP "" s of
  Left e -> Left $ S.ParseErr $ errorBundlePretty e
  Right tabs -> let (tabTypes, tabVals) = unzip tabs
                in  Right ( unflattenType tabTypes
                          , unflattenVal tabVals tabTypes)

parseTabType :: String -> S.Except TabType
parseTabType s = case parse tabTypeP "" s of
  Left e -> Left $ S.ParseErr $ errorBundlePretty e
  Right x -> Right x

topP :: Parser [(TabType, TabVal)]
topP = do blankLines >> some parseTab

parseTab :: Parser (TabType, TabVal)
parseTab = do
  tabType <- tabTypeP
  rows <- tabValP tabType
  blankLines
  return (tabType, rows)

tabTypeP :: Parser TabType
tabTypeP = do
  tabNames <- fullTabNameP <|> return []
  sectionTypes <- lineof $ sc >> scalarTreeP `sepBy` sc
  return $ makeTabType (tabNames ++ repeat []) sectionTypes

makeTabType :: [[RecName]] -> [Scalars] -> TabType
makeTabType names [st] = ValPart st
makeTabType (name:names) (st:sts) = TabType name st (makeTabType names sts)

fullTabNameP :: Parser [[RecName]]
fullTabNameP = lineof $ symbol ">" >> tabNameP `sepBy1` symbol "|"

tabNameP :: Parser [RecName]
tabNameP = recNameP `sepBy` char '.' <* sc

scalarTreeP :: Parser Scalars
scalarTreeP =     (symbol "()" >> return (flatLeaf UnitType))
              <|> fmap flatTree (recordP scalarTreeP)
              <|> fmap (flatLeaf . BaseType) baseTypeP

maybeNamed :: Parser a -> Parser (Maybe RecName, a)
maybeNamed p = do
  v <- optional . try $ recNameP <* symbol ":"
  x <- p
  return (v, x)

recordP :: Parser a -> Parser [(RecName, a)]
recordP p = mixedRecordPosNameList <$> (parens $ maybeNamed p `sepBy1` sc)

baseTypeP :: Parser S.BaseType
baseTypeP =     (symbol "Int"  >> return S.IntType)
            <|> (symbol "Bool" >> return S.BoolType)
            <|> (symbol "Real" >> return S.RealType)
            <|> (symbol "Str"  >> return S.StrType)

tabValP :: TabType -> Parser TabVal
tabValP tabType = let cols = getColTypes tabType
                      end = void eol <|> eof
                  in manyTill (rowP cols) end

rowP :: [ScalarType] -> Parser [ScalarVal]
rowP [] = lineof $ return []
rowP (t:ts) = do
  sc
  v <- optional $ fieldP t
  case v of
    Nothing -> lineof $ return []
    Just v' -> do {vs <- rowP ts; return (v':vs)}

fieldP :: ScalarType -> Parser ScalarVal
fieldP t = case t of
  BaseType b -> case b of
    S.IntType -> IntVal <$> int
    S.BoolType ->     (symbol "True"  >> return (BoolVal True ))
                  <|> (symbol "False" >> return (BoolVal False))
    S.StrType -> StrVal <$> stringLiteral
    S.RealType -> RealVal <$> real
  UnitType -> symbol "()" >> return UnitVal

recNameP :: Parser RecName
recNameP =     (RecPos  <$> (char '#' >> L.decimal))
           <|> (RecName <$> identifier)

identifier = makeIdentifier []