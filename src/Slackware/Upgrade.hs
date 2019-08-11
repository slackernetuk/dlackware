{-# Language OverloadedStrings #-}
module Slackware.Upgrade where

import qualified Data.ByteString.Char8 as C8
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Text as T
import qualified Data.Text.IO as Text.IO
import Data.Either (fromRight)
import Data.List (find)
import Data.Maybe ( isJust
                  , fromJust
                  )
import Slackware.Config as Config
import Slackware.CompileOrder
import Slackware.Info
import System.Directory ( createDirectoryIfMissing
                        , setCurrentDirectory
                        )
import System.FilePath ( (</>)
                       , (<.>)
                       , takeDirectory
                       , takeFileName
                       )
import System.Process ( callCommand
                      , readCreateProcess
                      , shell
                      )
import Text.Megaparsec (parse)

readConfiguration :: IO Config.Config
readConfiguration = do
    configContent <- BSL.readFile configPath
    let config = fromRight undefined $ Config.parseConfig configPath configContent

    createDirectoryIfMissing True $ T.unpack $ Config.loggingDirectory config
    return config

getCompileOrders :: Config.Config -> [FilePath]
getCompileOrders config =
    let f x = T.unpack (Config.reposRoot config) </> T.unpack x
     in fmap f (Config.repos config)


doCompileOrder :: String -> FilePath -> IO Bool
doCompileOrder needle compileOrder = do
    content <- Text.IO.readFile compileOrder
    let result = find lookup' $ packageList content
    return $ isJust result
  where
    lookup' (PackageName _ new) = new == T.pack needle
    packageList content = fromRight [] $ parseCompileOrder compileOrder content

findM :: (a -> IO Bool) -> [a] -> IO (Maybe a)
findM _ [] = return Nothing
findM f (x:xs) = do
    b <- f x
    if b then (return . Just) x else findM f xs

upgrade :: String -> String -> IO ()
upgrade pkgnam toVersion = do
    config <- readConfiguration

    let compileOrders = getCompileOrders config
    maybeMatchingCompileOrder <- findM (doCompileOrder pkgnam) compileOrders
    let matchingCompileOrder = fromJust maybeMatchingCompileOrder

    _ <- setCurrentDirectory $ takeDirectory matchingCompileOrder </> pkgnam

    let infoFile = pkgnam <.> "info"
    content <- C8.readFile infoFile

    pkg <- case parse parseInfoFile infoFile content of
        Left _ -> error "Unable to parse the .info file"
        Right pkg -> return pkg

    let c8version = version pkg
    let intermediate = T.replace c8version (T.pack toVersion) <$> downloads pkg
    let newDownloads = T.replace (major c8version) (major $ T.pack toVersion) <$> intermediate

    newChecksums' <- mapM downloader newDownloads
    let newChecksums = head . words <$> newChecksums'

    writeFile infoFile
          $ "PKGNAM=\"" ++ pkgnam ++ "\"\n"
         ++ "VERSION=\"" ++ toVersion ++ "\"\n"
         ++ "HOMEPAGE=\"" ++ (T.unpack . homepage) pkg ++ "\"\n"
         ++ "DOWNLOAD=\"" ++ T.unpack (T.unwords newDownloads) ++ "\"\n"
         ++ "MD5SUM=\"" ++ unwords newChecksums ++ "\"\n"

    let group = takeFileName . takeDirectory $ matchingCompileOrder
    callCommand $ "git add . && git commit -m \""
        ++ group ++ "/" ++ pkgnam
        ++ ": Updated for version " ++ toVersion ++ "\""

      where
        major fromVersion = T.init $ fst $ T.breakOnEnd "." fromVersion
        downloader url = flip readCreateProcess "" $ shell $ T.unpack $ T.concat
            [ "wget -q -O $(basename ", url, ") ", url, " && md5sum $(basename ", url, ")" ]
