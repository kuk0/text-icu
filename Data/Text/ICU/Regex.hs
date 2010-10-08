{-# LANGUAGE BangPatterns, EmptyDataDecls, ScopedTypeVariables #-}

-- |
-- Module      : Data.Text.ICU.Regex
-- Copyright   : (c) 2010 Bryan O'Sullivan
--
-- License     : BSD-style
-- Maintainer  : bos@serpentine.com
-- Stability   : experimental
-- Portability : GHC
--
-- Regular expression support for Unicode, implemented as bindings to
-- the International Components for Unicode (ICU) libraries.
--
-- The functions in this module are pure and hence thread safe, but
-- may not be as fast or as flexible as those in the
-- 'Data.Text.ICU.Regex.IO' module.
--
-- The syntax and behaviour of ICU regular expressions are Perl-like.
-- For complete details, see the ICU User Guide entry at
-- <http://userguide.icu-project.org/strings/regexp>.

module Data.Text.ICU.Regex
    (
    -- * Types
      MatchOption(..)
    , ParseError(errError, errLine, errOffset)
    , Match
    , Regex
    , Regular
    -- * Functions
    -- ** Construction
    , regex
    , regex'
    -- ** Inspection
    , pattern
    -- ** Searching
    , find
    , findAll
    -- ** Match groups
    -- $groups
    , groupCount
    , group
    , prefix
    , suffix
    , context
    ) where

import Control.Exception (catch)
import Data.String (IsString(..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Foreign as T
import Data.Text.ICU.Error.Internal (ParseError(..), handleError)
import qualified Data.Text.ICU.Regex.IO as IO
import Data.Text.ICU.Regex.Internal hiding (Regex(..), regex)
import qualified Data.Text.ICU.Regex.Internal as Internal
import Foreign.ForeignPtr (ForeignPtr, withForeignPtr)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (advancePtr)
import Foreign.Storable (peek)
import Prelude hiding (catch)
import System.IO.Unsafe (unsafeInterleaveIO, unsafePerformIO)

-- | A compiled regular expression.
--
-- 'Regex' values are usually constructed using the 'regex' or
-- 'regex'' functions.  This type is also an instance of 'IsString',
-- so if you have the @OverloadedStrings@ language extension enabled,
-- you can construct a 'Regex' by simply writing the pattern in
-- quotes (though this does not allow you to specify any 'Option's).
newtype Regex = Regex {
      reRe :: Internal.Regex
    }

instance Show Regex where
    show re = "Regex " ++ show (pattern re)

instance IsString Regex where
    fromString = regex [] . T.pack

-- | A match for a regular expression.
newtype Match = Match {
      matchRe :: Internal.Regex
    }

instance Show Match where
    show m = "Match" ++ case context 0 m of
                          Nothing -> ""
                          Just x -> ' ' : show x

-- | A typeclass for functions common to both 'Match' and 'Regex'
-- types.
class Regular r where
    regRe :: r -> Internal.Regex

    regFp :: r -> ForeignPtr URegularExpression
    regFp = Internal.reRe . regRe
    {-# INLINE regFp #-}

instance Regular Match where
    regRe = matchRe

instance Regular Regex where
    regRe = reRe

-- | Compile a regular expression with the given options.  This
-- function throws a 'ParseError' if the pattern is invalid, so it is
-- best for use when the pattern is statically known.
regex :: [MatchOption] -> Text -> Regex
regex opts pat = Regex . unsafePerformIO $ IO.regex opts pat

-- | Compile a regular expression with the given options.  This is
-- safest to use when the pattern is constructed at run time.
regex' :: [MatchOption] -> Text -> Either ParseError Regex
regex' opts pat = unsafePerformIO $
  ((Right . Regex) `fmap` Internal.regex opts pat) `catch`
  \(err::ParseError) -> return (Left err)

-- | Return the source form of the pattern used to construct this
-- regular expression or match.
pattern :: Regular r => r -> Text
pattern r = unsafePerformIO . withForeignPtr (regFp r) $ \rePtr ->
  alloca $ \lenPtr -> do
    textPtr <- handleError $ uregex_pattern rePtr lenPtr
    (T.fromPtr textPtr . fromIntegral) =<< peek lenPtr

-- | Find the first match for the regular expression in the given text.
find :: Regex -> Text -> Maybe Match
find re0 haystack = unsafePerformIO .
  matching re0 haystack $ \re -> do
    m <- IO.findNext re
    return $! if m then Nothing else Just (Match re)

-- | Lazily find all matches for the regular expression in the given
-- text.
findAll :: Regex -> Text -> [Match]
findAll re0 haystack = unsafePerformIO . unsafeInterleaveIO $ go 0
  where
    go !n = matching re0 haystack $ \re -> do
      f <- IO.find re n
      if f
        then maybe (return []) (fmap (Match re:) . go) =<< IO.end re 0
        else return []

matching :: Regex -> Text -> (IO.Regex -> IO a) -> IO a
matching (Regex re0) haystack act = do
  re <- IO.clone re0
  IO.setText re haystack
  act re

-- $groups
--
-- Capturing groups are numbered starting from zero.  Group zero is
-- always the entire matching text.  Groups greater than zero contain
-- the text matching each capturing group in a regular expression.

-- | Return the number of capturing groups in this regular
-- expression or match's pattern.
groupCount :: Regular r => r -> Int
groupCount = unsafePerformIO . IO.groupCount . regRe

-- | Return the /n/th capturing group in a match, or 'Nothing' if /n/
-- is out of bounds.
group :: Int -> Match -> Maybe Text
group n m = grouping n m $ \re -> do
  let n' = fromIntegral n
  start <- fromIntegral `fmap` IO.start_ re n'
  end <- fromIntegral `fmap` IO.end_ re n'
  (fp,_) <- IO.getText re
  withForeignPtr fp $ \ptr ->
    T.fromPtr (ptr `advancePtr` fromIntegral start) (end - start)

-- | Return the prefix of the /n/th capturing group in a match (the
-- text from the start of the string to the start of the match), or
-- 'Nothing' if /n/ is out of bounds.
prefix :: Int -> Match -> Maybe Text
prefix n m = grouping n m $ \re -> do
  start <- fromIntegral `fmap` IO.start_ re n
  (fp,_) <- IO.getText re
  withForeignPtr fp (`T.fromPtr` start)

-- | Return the suffix of the /n/th capturing group in a match (the
-- text from the end of the match to the end of the string), or
-- 'Nothing' if /n/ is out of bounds.
suffix :: Int -> Match -> Maybe Text
suffix n m = grouping n m $ \re -> do
  end <- fromIntegral `fmap` IO.end_ re n
  (fp,len) <- IO.getText re
  withForeignPtr fp $ \ptr -> do
    T.fromPtr (ptr `advancePtr` fromIntegral end) (len - end)

-- | Return ('prefix','group','suffix') of the /n/th capturing group
-- in a match, or 'Nothing' if /n/ is out of bounds.
context :: Int -> Match -> Maybe (Text,Text,Text)
context n m = grouping n m $ \re -> do
  start <- fromIntegral `fmap` IO.start_ re n
  end <- fromIntegral `fmap` IO.end_ re n
  (fp,len) <- IO.getText re
  withForeignPtr fp $ \ptr -> do
    pre <- T.fromPtr ptr start
    grp <- T.fromPtr (ptr `advancePtr` fromIntegral start) (end - start)
    suf <- T.fromPtr (ptr `advancePtr` fromIntegral end) (len - end)
    return (pre,grp,suf)

grouping :: Int -> Match -> (Internal.Regex -> IO a) -> Maybe a
grouping n (Match m) act = unsafePerformIO $ do
  count <- IO.groupCount m
  let n' = fromIntegral n
  if n < 0 || (n' >= count && count > 0)
    then return Nothing
    else Just `fmap` act m
