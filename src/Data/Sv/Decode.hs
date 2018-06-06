{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{-|
Module      : Data.Sv.Decode
Copyright   : (C) CSIRO 2017-2018
License     : BSD3
Maintainer  : George Wilson <george.wilson@data61.csiro.au>
Stability   : experimental
Portability : non-portable

This module contains data structures, combinators, and primitives for
decoding an 'Sv' into a list of your Haskell datatype.

A file can be read with 'parseDecodeFromFile'. If you already have the text
data in memory, it can be decoded with 'parseDecode'.
You will need a 'Decode' for your desired type.

A 'Decode' can be built using the primitives in this file. 'Decode'
is an 'Applicative' and an 'Data.Functor.Alt.Alt', allowing for composition
of these values with '<*>' and '<!>'

The primitive 'Decode's in this file which use 'ByteString' expect UTF-8
encoding. The Decode type has an instance of 'Data.Profunctor.Profunctor',
so you can 'lmap' or 'alterInput' to reencode on the way in.

This module is intended to be imported qualified like so

@
import qualified Data.Sv.Decode as D
@
-}

module Data.Sv.Decode (
  -- * The types
  Decode (..)
, Decode'
, Validation (..)
, DecodeValidation
, DecodeError (..)
, DecodeErrors (..)

, ParseOptions (..)
, Separator
, Headedness(..)

  -- * Running Decodes
, decode
, parseDecode
{-
, parseDecode'
, parseDecodeFromFile
, parseDecodeFromFile'
-}

-- * Convenience constructors and functions
, decodeMay
, decodeEither
, decodeEither'
, mapErrors
, alterInput

-- * Primitive Decodes
-- ** Field-based
, contents
, char
, byteString
, utf8
, lazyUtf8
, lazyByteString
, string
, int
, integer
, float
, double
, boolean
, boolean'
, ignore
, replace
, exactly
, emptyField
-- ** Row-based
, row

-- * Combinators
, choice
, element
, optionalField
, ignoreFailure
, orEmpty
, either
, orElse
, orElseE
, categorical
, categorical'
, (>>==)
, (==<<)
, bindDecode

-- * Building Decodes from Readable
, decodeRead
, decodeRead'
, decodeReadWithMsg

-- * Building Decodes from parsers
, withTrifecta
, withAttoparsec
, withParsec

-- * Working with errors
, onError
, decodeError
, unexpectedEndOfRow
, expectedEndOfRow
, unknownCategoricalValue
, badParse
, badDecode
, validateEither
, validateEither'
, validateMaybe
, validateMaybe'

-- * Implementation details
, runDecode
, buildDecode
, mkDecode
, promote
, promoteStrict
, promoteLazy
) where

import Prelude hiding (either)
import qualified Prelude

import Control.Lens (alaf, view)
import Control.Monad (unless)
--import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Reader (ReaderT (ReaderT))
import Control.Monad.State (state)
import qualified Data.Attoparsec.ByteString.Lazy as AL
import qualified Data.Attoparsec.ByteString as A
import Data.Bifunctor (first, second)
import Data.ByteString (ByteString)
import qualified Data.ByteString.UTF8 as UTF8
import qualified Data.ByteString.Lazy as LBS
import Data.Char (toUpper)
--import Data.Foldable (toList)
import Data.Functor.Alt (Alt ((<!>)))
import Data.Functor.Compose (Compose (Compose, getCompose))
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Monoid (First (First))
import Data.Profunctor (lmap)
import Data.Readable (Readable (fromBS))
import Data.Semigroup (Semigroup ((<>)), sconcat)
import Data.Semigroup.Foldable (asum1)
import Data.Set (Set, fromList, member)
import Data.String (IsString (fromString))
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8')
import qualified Data.Text.Lazy as LT
import Data.Validation (_Validation)
import Data.Vector (Vector, (!))
import qualified Data.Vector as V
import HaskellWorks.Data.Dsv.Lazy.Cursor as DSV
import HaskellWorks.Data.Dsv.Lazy.Cursor.Type
import Text.Parsec (Parsec)
import qualified Text.Parsec as P (parse)
import qualified Text.Trifecta as Tri

import Data.Sv.Alien.Cassava
import Data.Sv.Decode.Error
import Data.Sv.Decode.Type

-- | Does the 'Sv' have a 'Header' or not? A header is a row at the beginning
-- of a file which contains the string names of each of the columns.
--
-- If a header is present, it must not be decoded with the rest of the data.
data Headedness =
  Unheaded | Headed
  deriving (Eq, Ord, Show)

-- | By what are your values separated? The answer is often 'comma', but not always.
--
-- A 'Separator' is just a 'Char'. It could be a sum type instead, since it
-- will usually be comma or pipe, but our preference has been to be open here
-- so that you can use whatever you'd like. There are test cases, for example,
-- ensuring that you're free to use null-byte separated values if you so desire.
type Separator = Char

-- | The default separator
defaultSeparator :: Separator
defaultSeparator = ','

-- | The default is that a header is present.
defaultHeadedness :: Headedness
defaultHeadedness = Headed

-- | A 'ParseOptions' informs the parser how to parse your file.
--
-- A default is provided as 'defaultParseOptions', seen below.
data ParseOptions =
  ParseOptions {
  -- | Which separator does the file use? Usually this is 'comma', but it can
  -- also be 'pipe', or any other 'Char' ('Separator' = 'Char')
    _separator :: Separator

  -- | Whether there is a header row with column names or not.
  , _headedness :: Headedness
  }

defaultParseOptions :: ParseOptions
defaultParseOptions = ParseOptions defaultSeparator defaultHeadedness

-- | Decodes a sv into a list of its values using the provided 'Decode'
decode :: Decode' ByteString a -> DsvCursor -> DecodeValidation ByteString [a]
decode f = traverse (promoteLazy f) . DSV.toListVector

-- | Parse a 'ByteString' as an Sv, and then decode it with the given decoder.
--
-- This version uses 'Text.Trifecta.Trifecta' to parse the 'ByteString', which is assumed to
-- be UTF-8 encoded. If you want a different library, use 'parseDecode''.
parseDecode ::
  Decode' ByteString a
  -> ParseOptions
  -> LBS.ByteString
  -> DecodeValidation ByteString [a]
parseDecode f opts bs =
  let sep = _separator opts
      cursor = DSV.makeCursor sep bs
  in  decode f $ case _headedness opts of
        Unheaded -> cursor
        Headed   -> nextRow cursor

{-
-- | Parse text as an Sv, and then decode it with the given decoder.
--
-- This version lets you choose which parsing library to use by providing an
-- 'P.SvParser'. Common selections are 'P.trifecta' and 'P.attoparsecByteString'.
parseDecode' ::
  P.SvParser s
  -> Decode' s a
  -> ParseOptions s
  -> s
  -> DecodeValidation s [a]
parseDecode' svp d opts s =
  Prelude.either badDecode pure (P.parseSv' svp opts s) `bindValidation` decode d

-- | Load a file, parse it, and decode it.
--
-- This version uses Trifecta to parse the file, which is assumed to be UTF-8
-- encoded.
parseDecodeFromFile ::
  MonadIO m
  => Decode' ByteString a
  -> ParseOptions ByteString
  -> FilePath
  -> m (DecodeValidation ByteString [a])
parseDecodeFromFile = parseDecodeFromFile' P.trifecta

-- | Load a file, parse it, and decode it.
--
-- This version lets you choose which parsing library to use by providing an
-- 'P.SvParser'. Common selections are 'P.trifecta' and 'P.attoparsecByteString'.
parseDecodeFromFile' ::
  MonadIO m
  => P.SvParser s
  -> Decode' s a
  -> ParseOptions s
  -> FilePath
  -> m (DecodeValidation s [a])
parseDecodeFromFile' svp d opts fp = do
  sv <- P.parseSvFromFile' svp opts fp
  pure (Prelude.either badDecode pure sv `bindValidation` decode d)
-}

-- | Build a 'Decode', given a function that returns 'Maybe'.
--
-- Return the given error if the function returns 'Nothing'.
decodeMay :: DecodeError e -> (s -> Maybe a) -> Decode e s a
decodeMay e f = mkDecode (validateMaybe e . f)

-- | Build a 'Decode', given a function that returns 'Either'.
decodeEither :: (s -> Either (DecodeError e) a) -> Decode e s a
decodeEither f = mkDecode (validateEither . f)

-- | Build a 'Decode', given a function that returns 'Either', and a function to
-- build the error.
decodeEither' :: (e -> DecodeError e') -> (s -> Either e a) -> Decode e' s a
decodeEither' e f = mkDecode (validateEither' e . f)

-- | Get the contents of a field without doing any decoding. This never fails.
contents :: Decode e s s
contents = mkDecode pure

-- | Grab the whole row as a 'Vector'
row :: Decode e s (Vector s)
row =
  Decode . Compose . DecodeState . ReaderT $ \v ->
    state (const (pure v, Ind (V.length v)))

-- | Get a field that's a single char. This will fail if there are mulitple
-- characters in the field.
char :: Decode' ByteString Char
char = string >>== \cs -> case cs of
  [] -> badDecode "Expected single char but got empty string"
  (c:[]) -> pure c
  (_:_:_) -> badDecode ("Expected single char but got " <> UTF8.fromString cs)

-- | Get the contents of a field as a bytestring.
--
-- Alias for 'contents'
byteString :: Decode' ByteString ByteString
byteString = contents

-- | Get the contents of a UTF-8 encoded field as 'Text'
--
-- This will also work for ASCII text, as ASCII is a subset of UTF-8
utf8 :: Decode' ByteString Text
utf8 = contents >>==
  Prelude.either (badDecode . UTF8.fromString . show) pure . decodeUtf8'

-- | Get the contents of a field as a lazy 'Data.Text.Lazy.Text'
lazyUtf8 :: Decode' ByteString LT.Text
lazyUtf8 = LT.fromStrict <$> utf8

-- | Get the contents of a field as a lazy 'Data.ByteString.Lazy.ByteString'
lazyByteString :: Decode' ByteString LBS.ByteString
lazyByteString = LBS.fromStrict <$> contents

-- | Get the contents of a field as a 'String'
string :: Decode' ByteString String
string = UTF8.toString <$> contents

-- | Throw away the contents of a field. This is useful for skipping unneeded fields.
ignore :: Decode e s ()
ignore = replace ()

-- | Throw away the contents of a field, and return the given value.
replace :: a -> Decode e s a
replace a = a <$ contents

-- | Decode exactly the given string, or else fail.
exactly :: (Semigroup s, Eq s, IsString s) => s -> Decode' s s
exactly s = contents >>== \z ->
  if s == z
  then pure s
  else badDecode (sconcat ("'":|[z,"' was not equal to '",s,"'"]))

-- | Decode a UTF-8 'ByteString' field as an 'Int'
int :: Decode' ByteString Int
int = named "int"

-- | Decode a UTF-8 'ByteString' field as an 'Integer'
integer :: Decode' ByteString Integer
integer = named "integer"

-- | Decode a UTF-8 'ByteString' field as a 'Float'
float :: Decode' ByteString Float
float = named "float"

-- | Decode a UTF-8 'ByteString' field as a 'Double'
double :: Decode' ByteString Double
double = named "double"

-- | Decode a field as a 'Bool'
--
-- This aims to be tolerant to different forms a boolean might take.
boolean :: (IsString s, Ord s) => Decode' s Bool
boolean = boolean' fromString

-- | Decode a field as a 'Bool'. This version lets you provide the fromString
-- function that's right for you, since 'Data.String.IsString' on a
-- 'Data.ByteString.ByteString' will do the wrong thing in the case of many
-- encodings such as UTF-16 or UTF-32.
--
-- This aims to be tolerant to different forms a boolean might take.
boolean' :: Ord s => (String -> s) -> Decode' s Bool
boolean' s =
  categorical' [
    (False, fmap s ["false", "False", "FALSE", "f", "F", "0", "n", "N", "no", "No", "NO", "off", "Off", "OFF"])
  , (True, fmap s ["true", "True", "TRUE", "t", "T", "1", "y", "Y", "yes", "Yes", "YES", "on", "On", "ON"])
  ]

-- | Succeed only when the given field is the empty string.
--
-- The empty string surrounded in quotes or spaces is still the empty string.
emptyField :: (Eq s, IsString s, Semigroup s) => Decode' s ()
emptyField = contents >>== \c ->
  unless (c == fromString "") (badDecode ("Expected emptiness but got: " <> c))

-- | Choose the leftmost 'Decode' that succeeds. Alias for '<!>'
choice :: Decode e s a -> Decode e s a -> Decode e s a
choice = (<!>)

-- | Choose the leftmost 'Decode' that succeeds. Alias for 'asum1'
element :: NonEmpty (Decode e s a) -> Decode e s a
element = asum1

-- | Try the given 'Decode'. If it fails, instead succeed with 'Nothing'.
ignoreFailure :: Decode e s a -> Decode e s (Maybe a)
ignoreFailure a = Just <$> a <!> Nothing <$ ignore

-- | If the field is the empty string, succeed with 'Nothing'.
-- Otherwise try the given 'Decode'.
orEmpty :: (Eq s, IsString s, Semigroup s) => Decode' s a -> Decode' s (Maybe a)
orEmpty a = Nothing <$ emptyField <!> Just <$> a

-- | Try the given 'Decode'. If it fails, succeed without consuming anything.
--
-- This usually isn't what you want. 'ignoreFailure' and 'orEmpty' are more
-- likely what you are after.
optionalField :: Decode e s a -> Decode e s (Maybe a)
optionalField a = Just <$> a <!> pure Nothing

-- | Try the first, then try the second, and wrap the winner in an 'Either'.
--
-- This is left-biased, meaning if they both succeed, left wins.
either :: Decode e s a -> Decode e s b -> Decode e s (Either a b)
either a b = fmap Left a <!> fmap Right b

-- | Try the given decoder, otherwise succeed with the given value.
orElse :: Decode e s a -> a -> Decode e s a
orElse f a = f <!> replace a

-- | Try the given decoder, or if it fails succeed with the given value, in an 'Either'.
orElseE :: Decode e s b -> a -> Decode e s (Either a b)
orElseE b a = fmap Right b <!> replace (Left a)

-- | Decode categorical data, given a list of the values and the strings which match them.
--
-- Usually this is used with sum types with nullary constructors.
--
-- > data TrafficLight = Red | Amber | Green
-- > categorical [(Red, "red"), (Amber, "amber"), (Green, "green")]
categorical :: (Ord s, Show a) => [(a, s)] -> Decode' s a
categorical = categorical' . fmap (fmap pure)

-- | Decode categorical data, given a list of the values and lists of strings
-- which match them.
--
-- This version allows for multiple strings to match each value, which is
-- useful for when the categories are inconsistently labelled.
--
-- > data TrafficLight = Red | Amber | Green
-- > categorical' [(Red, ["red", "R"]), (Amber, ["amber", "orange", "A"]), (Green, ["green", "G"])]
--
-- For another example of its usage, see the source for 'boolean'.
categorical' :: forall s a . (Ord s, Show a) => [(a, [s])] -> Decode' s a
categorical' as =
  let as' :: [(a, Set s)]
      as' = fmap (second fromList) as
      go :: s -> (a, Set s) -> Maybe a
      go s (a, set) =
        if s `member` set
        then Just a
        else Nothing
  in  contents >>== \s ->
    validateMaybe (UnknownCategoricalValue s (fmap snd as)) $
      alaf First foldMap (go s) as'

-- | Use the 'Readable' instance to try to decode the given value.
decodeRead :: Readable a => Decode' ByteString a
decodeRead = decodeReadWithMsg (mappend "Couldn't parse ")

-- | Use the 'Readable' instance to try to decode the given value,
-- or fail with the given error message.
decodeRead' :: Readable a => ByteString -> Decode' ByteString a
decodeRead' e = decodeReadWithMsg (const e)

-- | Use the 'Readable' instance to try to decode the given value,
-- or use the value to build an error message.
decodeReadWithMsg :: Readable a => (ByteString -> e) -> Decode e ByteString a
decodeReadWithMsg e = contents >>== \c ->
  maybe (badDecode (e c)) pure . fromBS $ c

-- | Given the name of a type, try to decode it using 'Readable', 
named :: Readable a => ByteString -> Decode' ByteString a
named name =
  let vs' = ['a','e','i','o','u']
      vs  = fmap toUpper vs' ++ vs'
      n c = if c `elem` vs then "n" else ""
      n' = foldMap (n . fst) . UTF8.uncons
      n'' = n' name
      space = " "
  in  decodeReadWithMsg $ \bs ->
        mconcat ["Couldn't parse \"", bs, "\" as a", n'', space, name]

-- | Map over the errors of a 'Decode'
--
-- To map over the other two parameters, use the 'Data.Profunctor.Profunctor' instance.
mapErrors :: (e -> x) -> Decode e s a -> Decode x s a
mapErrors f (Decode (Compose r)) = Decode (Compose (fmap (first (fmap f)) r))

-- | This transforms a @Decode' s a@ into a @Decode' t a@. It needs
-- functions in both directions because the errors can include fragments of the
-- input.
--
-- @alterInput :: (s -> t) -> (t -> s) -> Decode' s a -> Decode' t a@
alterInput :: (e -> x) -> (t -> s) -> Decode e s a -> Decode x t a
alterInput f g = mapErrors f . lmap g

---- Promoting parsers to 'Decode's

-- | Build a 'Decode' from a Trifecta parser
withTrifecta :: Tri.Parser a -> Decode' ByteString a
withTrifecta =
  mkParserFunction
    (validateTrifectaResult (BadDecode . UTF8.fromString))
    (flip Tri.parseByteString mempty)

-- | Build a 'Decode' from an Attoparsec parser
withAttoparsec :: A.Parser a -> Decode' ByteString a
withAttoparsec =
  mkParserFunction
    (validateEither' (BadDecode . fromString))
    A.parseOnly

-- | Build a 'Decode' from a Parsec parser
withParsec :: Parsec ByteString () a -> Decode' ByteString a
withParsec =
  -- Parsec will include a position, but it will only confuse the user
  -- since it won't correspond obviously to a position in their source file.
  let dropPos = drop 1 . dropWhile (/= ':')
  in  mkParserFunction
    (validateEither' (BadDecode . UTF8.fromString . dropPos . show))
    (\p s -> P.parse p mempty s)

mkParserFunction ::
  Tri.CharParsing p
  => (f a -> DecodeValidation ByteString a)
  -> (p a -> ByteString -> f a)
  -> p a
  -> Decode' ByteString a
mkParserFunction err run p =
  let p' = p <* Tri.eof
  in  byteString >>== (err . run p')
{-# INLINE mkParserFunction #-}

-- | Convenience to get the underlying function out of a Decode in a useful form
runDecode :: Decode e s a -> Vector s -> Ind -> (DecodeValidation e a, Ind)
runDecode = runDecodeState . getCompose . unwrapDecode
{-# INLINE runDecode #-}

-- | This can be used to build a 'Decode' whose value depends on the
-- result of another 'Decode'. This is especially useful since 'Decode' is not
-- a 'Monad'.
--
-- If you need something like this but with more power, look at 'bindDecode'
(>>==) :: Decode e s a -> (a -> DecodeValidation e b) -> Decode e s b
(>>==) = flip (==<<)
infixl 1 >>==
{-# INLINE (>>==) #-}

-- | flipped '>>=='
(==<<) :: (a -> DecodeValidation e b) -> Decode e s a -> Decode e s b
(==<<) f (Decode c) =
  Decode (rmapC (`bindValidation` (view _Validation . f)) c)
    where
      rmapC g (Compose fga) = Compose (fmap g fga)
infixr 1 ==<<

-- | Bind through a 'Decode'.
--
-- This bind does not agree with the 'Applicative' instance because it does
-- not accumulate multiple error values. This is a violation of the 'Monad'
-- laws, meaning 'Decode' is not a 'Monad'.
--
-- That is not to say that there is anything wrong with using this function.
-- It can be quite useful.
bindDecode :: Decode e s a -> (a -> Decode e s b) -> Decode e s b
bindDecode d f =
  buildDecode $ \v i ->
    case runDecode d v i of
      (Failure e, i') -> (Failure e, i')
      (Success a, i') -> runDecode (f a) v i'

-- | Run a 'Decode', and based on its errors build a new 'Decode'.
onError :: Decode e s a -> (DecodeErrors e -> Decode e s a) -> Decode e s a
onError d f =
  buildDecode $ \v i ->
    case runDecode d v i of
      (Failure e, i') -> runDecode (f e) v i'
      (Success a, i') -> (Success a, i')

-- | Build a 'Decode' from a function.
--
-- This version gives you just the contents of the field, with no information
-- about the spacing or quoting around that field.
mkDecode :: (s -> DecodeValidation e a) -> Decode e s a
mkDecode f =
  Decode . Compose . DecodeState . ReaderT $ \v -> state $ \(Ind i) ->
    if i >= length v
    then (unexpectedEndOfRow, Ind i)
    else (f (v ! i), Ind (i+1))

-- | promotes a Decode to work on a whole 'Record' at once. This does not need
-- to be called by the user. Instead use 'decode'.
promote :: forall a bs. (forall x. A.Parser x -> bs -> Either ByteString x) -> Decode' ByteString a -> Vector bs -> DecodeValidation ByteString a
promote parse dec vecLazy =
  let len = length vecLazy
      toField :: bs -> DecodeValidation ByteString ByteString
      toField = Prelude.either badParse pure . parse (field 44)
      vecFieldVal :: DecodeValidation ByteString (Vector ByteString)
      vecFieldVal = traverse toField vecLazy
  in  bindValidation vecFieldVal $ \vecField ->
  case runDecode dec vecField (Ind 0) of
    (d, Ind i) ->
      if i >= len
      then d
      else d *> expectedEndOfRow (V.force (V.drop i vecField))

promoteStrict :: Decode' ByteString a -> Vector ByteString -> DecodeValidation ByteString a
promoteStrict = promote (\p b -> first UTF8.fromString $ A.parseOnly p b)

promoteLazy :: Decode' ByteString a -> Vector LBS.ByteString -> DecodeValidation ByteString a
promoteLazy = promote (\p b -> first UTF8.fromString $ AL.eitherResult $ AL.parse p b)
