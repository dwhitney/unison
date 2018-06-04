{-# Language OverloadedStrings #-}

module Unison.FileParser where

-- import           Text.Parsec.Prim (ParsecT)
-- import qualified Unison.TypeParser as TypeParser
import Prelude hiding (readFile)
import           Unison.Parser
import Control.Applicative
import Data.Either (partitionEithers)
import Data.Map (Map)
import Unison.DataDeclaration (DataDeclaration(..), hashDecls,
                               EffectDeclaration(..), mkEffectDecl)
import Unison.Parser (PEnv, penv0)
import Unison.Parsers (unsafeGetRight)
import Unison.Reference (Reference)
import Unison.Symbol (Symbol)
import Unison.Term (Term)
import Unison.TypeParser (S)
import Unison.Var (Var)
import qualified Data.Map as Map
import qualified Text.Parsec.Layout as L
import qualified Unison.Parsers as Parsers
import qualified Unison.Type as Type
import qualified Unison.TermParser as TermParser
import qualified Unison.TypeParser as TypeParser
import qualified Unison.Var as Var
import Control.Monad.Reader
import Data.Text.IO (readFile)
import System.IO (FilePath)
import qualified Data.Text as Text
import Debug.Trace

data UnisonFile v = UnisonFile {
  dataDeclarations :: Map v (DataDeclaration v),
  effectDeclarations :: Map v (EffectDeclaration v),
  term :: Term v
} deriving (Show)

unsafeParseFile :: String -> PEnv -> UnisonFile Symbol
unsafeParseFile s env = unsafeGetRight $ parseFile "" s env

parseFile :: FilePath -> String -> PEnv -> Either String (UnisonFile Symbol)
parseFile filename s = Unison.Parser.run' (Unison.Parser.root file) s Parsers.s0 filename

parseFile' :: FilePath -> String -> Either String (UnisonFile Symbol)
parseFile' filename s = parseFile filename s penv0

unsafeReadAndParseFile' :: String -> IO (UnisonFile Symbol)
unsafeReadAndParseFile' = unsafeReadAndParseFile penv0

unsafeReadAndParseFile :: PEnv -> String -> IO (UnisonFile Symbol)
unsafeReadAndParseFile env filename = do
  txt <- readFile filename
  let str = Text.unpack txt
  pure $ unsafeGetRight (parseFile filename str env)

file :: Var v => Parser (S v) (UnisonFile v)
file = traced "file" $ do
  (dataDecls, effectDecls) <- traced "declarations" declarations
  local (`Map.union` environmentFor dataDecls effectDecls) $ do
    term <- TermParser.block
    pure $ UnisonFile dataDecls effectDecls term

environmentFor :: Var v => Map v (DataDeclaration v) -> Map v (EffectDeclaration v) -> PEnv
environmentFor dataDecls effectDecls = -- todo: add effectDecls
  trace "new env" $ traceShowId $ Map.fromList (constructors' =<< hashDecls (Map.union dataDecls (toDataDecl <$> effectDecls)))

constructors' :: Var v => (v, Reference, DataDeclaration v) -> [(String, (Reference, Int))]
constructors' (typeSymbol, r, (DataDeclaration _ constructors)) =
  let qualCtorName ((ctor,_), i) =
       (Text.unpack $ mconcat [Var.qualifiedName typeSymbol, ".", Var.qualifiedName ctor], (r, i))
  in qualCtorName <$> constructors `zip` [0..]

declarations :: Var v => Parser (S v)
                         (Map v (DataDeclaration v),
                          Map v (EffectDeclaration v))
declarations = do
  declarations <- many ((Left <$> dataDeclaration) <|> Right <$> effectDeclaration)
  let (dataDecls, effectDecls) = partitionEithers declarations
  pure (Map.fromList dataDecls, Map.fromList effectDecls)


dataDeclaration :: Var v => Parser (S v) (v, DataDeclaration v)
dataDeclaration = traced "data declaration" $ do
  token_ $ string "type"
  (name, typeArgs) <- --L.withoutLayout "type introduction" $
    (,) <$> TermParser.prefixVar <*> traced "many prefixVar" (many TermParser.prefixVar)
  traced "=" . token_ $ string "="
  -- dataConstructorTyp gives the type of the constructor, given the types of
  -- the constructor arguments, e.g. Cons becomes forall a . a -> List a -> List a
  let dataConstructorTyp ctorArgs =
        Type.foralls typeArgs $ Type.arrows ctorArgs (Type.apps (Type.var name) (Type.var <$> typeArgs))
      dataConstructor =
        (,) <$> TermParser.prefixVar
            <*> (dataConstructorTyp <$> many TypeParser.valueTypeLeaf)
  traced "vblock" $ L.vblockIncrement $ do
    constructors <- traced "constructors" $ sepBy (token_ $ string "|") dataConstructor
    pure $ (name, DataDeclaration typeArgs constructors)


effectDeclaration :: Var v => Parser (S v) (v, EffectDeclaration v)
effectDeclaration = traced "effect declaration" $ do
  token_ $ string "effect"
  name <- TermParser.prefixVar
  typeArgs <- many TermParser.prefixVar
  token_ $ string "where"
  L.vblockNextToken $ do
    constructors <- sepBy L.vsemi constructor
    pure $ (name, mkEffectDecl typeArgs constructors)
  where
    constructor = (,) <$> (TermParser.prefixVar <* token_ (string ":")) <*> traced "computation type" TypeParser.computationType
