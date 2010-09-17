{-# LANGUAGE BangPatterns, EmptyDataDecls, ForeignFunctionInterface,
    RecordWildCards #-}
-- |
-- Module      : Data.Text.ICU.Break
-- Copyright   : (c) 2010 Bryan O'Sullivan
--
-- License     : BSD-style
-- Maintainer  : bos@serpentine.com
-- Stability   : experimental
-- Portability : GHC
--
-- String breaking functions for Unicode, implemented as bindings to
-- the International Components for Unicode (ICU) libraries.
--
-- The text boundary positions are found according to the rules described in
-- Unicode Standard Annex #29, Text Boundaries, and Unicode Standard Annex
-- #14, Line Breaking Properties.  These are available at
-- <http://www.unicode.org/reports/tr14/> and
-- <http://www.unicode.org/reports/tr29/>.

module Data.Text.ICU.Break
    (
    -- * Types
      Breaker
    , Line(..)
    , Word(..)
    -- * Breaking functions
    , breakCharacter
    , breakLine
    , breakSentence
    , breakWord
    , setText
    -- * Iteration functions
    , first
    , last
    , next
    , previous
    , getStatus
    , getStatuses
    ) where

#include <unicode/ubrk.h>

import Data.Int (Int32)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text.Foreign (dropWord16, takeWord16, useAsPtr)
import Data.Text.ICU.Error.Internal (UErrorCode, handleError)
import Data.Text.ICU.Internal (LocaleName, UChar, withLocaleName)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt)
import Foreign.ForeignPtr (ForeignPtr, newForeignPtr, withForeignPtr)
import Foreign.Marshal.Array (allocaArray, peekArray)
import Foreign.Ptr (FunPtr, Ptr, nullPtr)
import Prelude hiding (last)

-- | Line break status.
data Line = Soft                -- ^ A soft line break is a position at
                                -- which a line break is acceptable, but not
                                -- required.
          | Hard
            deriving (Eq, Show, Enum)

-- | Word break status.
data Word = Uncategorized       -- ^ A "word" that does not fit into another
                                -- category.  Includes spaces and most
                                -- punctuation.
          | Number              -- ^ A word that appears to be a number.
          | Letter              -- ^ A word containing letters, excluding
                                -- hiragana, katakana or ideographic
                                -- characters.
          | Kana                -- ^ A word containing kana characters.
          | Ideograph           -- ^ A word containing ideographic characters.
            deriving (Eq, Show, Enum)

-- A boundary breaker.
data Breaker a = BR {
      brText :: IORef Text
    , brStatus :: Int32 -> a
    , brIter :: ForeignPtr UBreakIterator
    }

-- | Break a string on character boundaries.
--
-- Character boundary analysis identifies the boundaries of "Extended
-- Grapheme Clusters", which are groupings of codepoints that should be
-- treated as character-like units for many text operations.  Please see
-- Unicode Standard Annex #29, Unicode Text Segmentation,
-- <http://www.unicode.org/reports/tr29/> for additional information on
-- grapheme clusters and guidelines on their use.
breakCharacter :: LocaleName -> Text -> IO (Breaker ())
breakCharacter = open (#const UBRK_CHARACTER) (const ())

-- | Break a string on line boundaries.
--
-- Line boundary analysis determines where a text string can be broken when
-- line wrapping. The mechanism correctly handles punctuation and hyphenated
-- words.
breakLine :: LocaleName -> Text -> IO (Breaker Line)
breakLine = open (#const UBRK_LINE) asLine
  where
    asLine i
      | i < (#const UBRK_LINE_SOFT_LIMIT) = Soft
      | i < (#const UBRK_LINE_HARD_LIMIT) = Hard
      | otherwise = error $ "unknown line break status " ++ show i

-- | Break a string on sentence boundaries.
--
-- Sentence boundary analysis allows selection with correct interpretation
-- of periods within numbers and abbreviations, and trailing punctuation
-- marks such as quotation marks and parentheses.
breakSentence :: LocaleName -> Text -> IO (Breaker ())
breakSentence = open (#const UBRK_SENTENCE) (const ())

-- | Break a string on word boundaries.
--
-- Word boundary analysis is used by search and replace functions, as well
-- as within text editing applications that allow the user to select words
-- with a double click. Word selection provides correct interpretation of
-- punctuation marks within and following words. Characters that are not
-- part of a word, such as symbols or punctuation marks, have word breaks on
-- both sides.
breakWord :: LocaleName -> Text -> IO (Breaker Word)
breakWord = open (#const UBRK_WORD) asWord
  where
    asWord i
      | i < (#const UBRK_WORD_NONE_LIMIT) = Uncategorized
      | i < (#const UBRK_WORD_NUMBER_LIMIT) = Number
      | i < (#const UBRK_WORD_LETTER_LIMIT) = Letter
      | i < (#const UBRK_WORD_KANA_LIMIT) = Kana
      | i < (#const UBRK_WORD_IDEO_LIMIT) = Ideograph
      | otherwise = error $ "unknown word break status " ++ show i

-- | Create a new 'Breaker' for locating text boundaries in the
-- specified locale.
open :: UBreakIteratorType -> (Int32 -> a) -> LocaleName -> Text
     -> IO (Breaker a)
open brk f loc t = withLocaleName loc $ \locale ->
  useAsPtr t $ \ptr len -> do
    bi <- handleError $ ubrk_open brk locale ptr (fromIntegral len)
    r <- newIORef t
    BR r f `fmap` newForeignPtr ubrk_close bi

-- | Point an existing 'Breaker' at a new piece of text.
setText :: Breaker a -> Text -> IO ()
setText BR{..} t =
  useAsPtr t $ \ptr len -> do
    withForeignPtr brIter $ \p -> handleError $
                                  ubrk_setText p ptr (fromIntegral len)
    writeIORef brText t

asIndex :: (Ptr UBreakIterator -> IO Int32) -> Breaker a
        -> IO (Maybe (Text, Text))
asIndex act BR{..} = do
  ix <- withForeignPtr brIter act
  if ix == (#const UBRK_DONE)
    then return Nothing
    else do
      let n = fromIntegral ix
      t <- readIORef brText
      return $! Just (takeWord16 n t, dropWord16 n t)

-- | Reset the iterator and break at the first character in the text being
-- scanned.
first :: Breaker a -> IO (Maybe (Text, Text))
first = asIndex ubrk_first

-- | Reset the iterator and break immediately /beyond/ the last character in
-- the text being scanned.
last :: Breaker a -> IO (Maybe (Text, Text))
last = asIndex ubrk_last

-- | Advance the iterator and break at the text boundary that follows the
-- current text boundary.
next :: Breaker a -> IO (Maybe (Text, Text))
next = asIndex ubrk_next

-- | Advance the iterator and break at the text boundary that precedes the
-- current text boundary.
previous :: Breaker a -> IO (Maybe (Text, Text))
previous = asIndex ubrk_previous

-- | Return the status from the break rule that determined the most recently
-- returned break position.  For rules that do not specify a status, a
-- default value of @()@ is returned.
getStatus :: Breaker a -> IO a
getStatus BR{..} = brStatus `fmap` withForeignPtr brIter ubrk_getRuleStatus

-- | Return statuses from all of the break rules that determined the most
-- recently returned break position.
getStatuses :: Breaker a -> IO [a]
getStatuses BR{..} =
  withForeignPtr brIter $ \brk -> do
    n <- handleError $ ubrk_getRuleStatusVec brk nullPtr 0
    allocaArray (fromIntegral n) $ \ptr -> do
      _ <- handleError $ ubrk_getRuleStatusVec brk ptr n
      map brStatus `fmap` peekArray (fromIntegral n) ptr

type UBreakIteratorType = CInt
data UBreakIterator

foreign import ccall unsafe "hs_text_icu.h __hs_ubrk_open" ubrk_open
    :: UBreakIteratorType -> CString -> Ptr UChar -> Int32 -> Ptr UErrorCode
    -> IO (Ptr UBreakIterator)

foreign import ccall unsafe "hs_text_icu.h __hs_ubrk_setText" ubrk_setText
    :: Ptr UBreakIterator -> Ptr UChar -> Int32 -> Ptr UErrorCode
    -> IO ()

foreign import ccall unsafe "hs_text_icu.h &__hs_ubrk_close" ubrk_close
    :: FunPtr (Ptr UBreakIterator -> IO ())

foreign import ccall unsafe "hs_text_icu.h __hs_ubrk_first" ubrk_first
    :: Ptr UBreakIterator -> IO Int32

foreign import ccall unsafe "hs_text_icu.h __hs_ubrk_last" ubrk_last
    :: Ptr UBreakIterator -> IO Int32

foreign import ccall unsafe "hs_text_icu.h __hs_ubrk_next" ubrk_next
    :: Ptr UBreakIterator -> IO Int32

foreign import ccall unsafe "hs_text_icu.h __hs_ubrk_previous" ubrk_previous
    :: Ptr UBreakIterator -> IO Int32

foreign import ccall unsafe "hs_text_icu.h __hs_ubrk_getRuleStatus" ubrk_getRuleStatus
    :: Ptr UBreakIterator -> IO Int32

foreign import ccall unsafe "hs_text_icu.h __hs_ubrk_getRuleStatusVec" ubrk_getRuleStatusVec
    :: Ptr UBreakIterator -> Ptr Int32 -> Int32 -> Ptr UErrorCode -> IO Int32
