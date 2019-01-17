module Parser (IdxVarName, Expr (..), Pat (..),
               IdxPat, IdxExpr (..), parseCommand, parseProg) where
import Util
import Record
-- import Typer
import ParseUtil
import qualified Syntax as S
import qualified Env as E

import Control.Monad
import Test.HUnit
import qualified Data.Map.Strict as M

import Data.Monoid ((<>))
import Control.Monad (void)
import Control.Monad.Combinators.Expr
import Text.Megaparsec
import Text.Megaparsec.Char hiding (space)
import qualified Text.Megaparsec.Char.Lexer as L

data Expr = Lit S.LitVal
          | Var VarName
          | Let Pat Expr Expr
          | Lam Pat Expr
          | App Expr Expr
          | For IdxPat Expr
          | Get Expr IdxExpr
          | RecCon (Record Expr)
              deriving (Show, Eq)

data IdxExpr = IdxVar IdxVarName
             | IdxRecCon (Record IdxExpr)
                 deriving (Show, Eq)

type IdxPat = Pat
data Pat = VarPat VarName
         | RecPat (Record Pat) deriving (Show, Eq)

type VarName = String
type IdxVarName = String
type Decl = (Pat, Expr)
type Command = (S.DeclInstr Expr)

parseProg :: String -> Either String [S.TopDecl Expr]
parseProg s = case parse (prog <* eof) "" s of
  Left  e -> Left $ errorBundlePretty e
  Right p -> Right $
    let sourceLines = lines s
        showLine n = "L" ++ show n ++ ": " ++ (sourceLines !! (n - 1))
    in [S.TopDecl (showLine lineNum) cmd | (lineNum, cmd) <- p ]

parseCommand :: String -> Either String (S.TopDecl Expr)
parseCommand s = case parse (command <* eof) "" s of
  Left  e -> Left $ errorBundlePretty e
  Right p -> Right $ S.TopDecl "" p

prog :: Parser [(Int, Command)]
prog = emptyLines >> many (commandWithPos <*emptyLines)

commandWithPos :: Parser (Int, Command)
commandWithPos = do SourcePos _ linePos _ <- getSourcePos
                    cmd <- command
                    return (unPos linePos, cmd)

command :: Parser Command
command =   explicitCommand
        <|> do (v, e) <- try topDecl
               return $ S.EvalDecl v e
        <|> liftM (S.EvalCmd S.EvalExpr) expr
        <?> "top-level declaration"

opNames = ["+", "*", "/", "-", "^"]
resNames = ["for", "lam", "let", "in"]

identifier = makeIdentifier resNames

appRule = InfixL (sc
                  *> notFollowedBy (choice . map symbol $ opNames ++ resNames)
                  >> return App)
binOpRule opchar opname = InfixL (symbol opchar
                                 >> return (binOpApp opname))

binOpApp :: String -> Expr -> Expr -> Expr
binOpApp s e1 e2 = App (App (Var s) e1) e2

getRule = Postfix $ do
  vs  <- many $ symbol "." >> idxExpr
  return $ \body -> foldr (flip Get) body (reverse vs)

ops = [ [getRule, appRule]
      , [binOpRule "^" "pow"]
      , [binOpRule "*" "mul", binOpRule "/" "div"]
      , [binOpRule "+" "add", binOpRule "-" "sub"]
      ]

term =   parenExpr
     <|> liftM Var identifier
     <|> liftM Lit literal
     <|> letExpr
     <|> lamExpr
     <|> forExpr
     <?> "term"

idxPat = pat

idxExpr =   parenIdxExpr
        <|> liftM IdxVar identifier

pat :: Parser Pat
pat =   parenPat
    <|> liftM VarPat identifier

parenPat :: Parser Pat
parenPat = do
  xs <- parens $ maybeNamed pat `sepBy` symbol ","
  return $ case xs of
    [(Nothing, x)] -> x
    xs -> RecPat $ mixedRecord xs

expr :: Parser Expr
expr = makeExprParser (sc >> term) ops

topDecl :: Parser (VarName, Expr)
topDecl = do
  (v, wrap) <- try $ do v <- identifier
                        wrap <- idxLhsArgs <|> lamLhsArgs
                        symbol "="
                        return (v, wrap)
  body <- expr
  return (v, wrap body)

decl :: Parser Decl
decl = do
  v <- pat
  wrap <- idxLhsArgs <|> lamLhsArgs
  symbol "="
  body <- expr
  return (v, wrap body)

-- typedName :: Parser (String, BaseType)
-- typedName = do
--   name <- identifier
--   symbol "::"
--   typeName <- identifier
--   ty <- case typeName of
--     "Int"  -> return IntType
--     "Str"  -> return StrType
--     "Real" -> return RealType
--     _      -> fail $ show typeName ++ " is not a valid type"
--   return (name, ty)

explicitCommand :: Parser Command
explicitCommand = do
  try $ symbol ":"
  cmdName <- identifier
  e <- expr
  cmd <- case cmdName of
           "p"     -> return S.EvalExpr
           "t"     -> return S.GetType
           "sysf"  -> return S.GetTyped
           "parse" -> return S.GetParse
           "lower" -> return S.GetLowered
           "llvm"  -> return S.GetLLVM
           "jit"   -> return S.EvalJit
           _   -> fail $ "unrecognized command: " ++ show cmdName
  return $ S.EvalCmd cmd e

maybeNamed :: Parser a -> Parser (Maybe String, a)
maybeNamed p = do
  v <- optional $ try $
    do v <- identifier
       symbol "="
       return v
  x <- p
  return (v, x)

literal :: Parser S.LitVal
literal = lexeme $  fmap S.IntLit  (try (int <* notFollowedBy (char '.')))
                <|> fmap S.RealLit real
                <|> fmap S.StrLit stringLiteral


parenIdxExpr = do
  elts <- parens $ maybeNamed idxExpr `sepBy` symbol ","
  return $ case elts of
    [(Nothing, expr)] -> expr
    elts -> IdxRecCon $ mixedRecord elts

parenExpr = do
  elts <- parens $ maybeNamed expr `sepBy` symbol ","
  return $ case elts of
    [(Nothing, expr)] -> expr
    elts -> RecCon $ mixedRecord elts

idxLhsArgs = do
  try $ symbol "."
  args <- idxPat `sepBy` symbol "."
  return $ \body -> foldr For body args

lamLhsArgs = do
  args <- pat `sepBy` sc
  return $ \body -> foldr Lam body args

letExpr = do
  try $ symbol "let"
  bindings <- decl `sepBy` symbol ";"
  symbol "in"
  body <- expr
  return $ foldr (uncurry Let) body bindings

lamExpr = do
  try $ symbol "lam"
  ps <- pat `sepBy` sc
  symbol ":"
  body <- expr
  return $ foldr Lam body ps

forExpr = do
  try $ symbol "for"
  vs <- some idxPat -- `sepBy` sc
  symbol ":"
  body <- expr
  return $ foldr For body vs
