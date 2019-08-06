{-# LANGUAGE OverloadedStrings #-}
module Slackware.Command ( build
                         , downloadSource
                         , install
                         ) where

import Conduit
import Slackware.Arch ( grepSlackBuild
                      , uname
                      )
import Slackware.CompileOrder ( Step(..)
                              , parseCompileOrder
                              )
import Slackware.Log ( Level(..)
                     , console
                     )
import qualified Slackware.Config as Config
import Slackware.Package
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Exception ( IOException
                         , try
                         )
import Control.Monad.Trans.Except
import Control.Monad.Trans.Reader
import Crypto.Hash ( Digest
                   , MD5
                   , hashlazy
                   )
import Data.Foldable ( foldlM
                     , foldrM
                     )
import qualified Data.ByteString.Char8 as C8
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Text as T
import qualified Data.Text.IO as T.IO
import Network.HTTP.Req ( HttpException
                        , Req
                        , defaultHttpConfig
                        , runReq
                        )
import Slackware.Info ( parseInfoFile
                      , PackageInfo(..)
                      )
import Slackware.Download ( filename
                          , get
                          )
import Slackware.Error
import Slackware.Process ( outErrProcess
                         , runSlackBuild
                         )
import System.Directory ( createDirectoryIfMissing
                        , doesFileExist
                        , getCurrentDirectory
                        , setCurrentDirectory
                        )
import System.Exit ( ExitCode(..)
                   , exitFailure
                   )
import System.FilePath ( FilePath
                       , (</>)
                       , (<.>)
                       , joinPath
                       , takeDirectory
                       )
import System.IO.Error (tryIOError)
import System.Process ( readProcess
                      , callProcess
                      )
import Text.Megaparsec ( errorBundlePretty
                       , parse
                       )

md5sum :: BSL.ByteString -> Digest MD5
md5sum = hashlazy

installpkg :: T.Text -> String -> ExceptT PackageError (ReaderT PackageEnvironment IO) ()
installpkg old fullPkgName =
    tryIO >>= either (throwE . PackageError fullPkgName . InstallError) return
    where
        tryIO = liftIO $ tryIOError callProcess'
        fullPath = "/var/cache/dlackware/" ++ fullPkgName ++ ".txz"
        callProcess' = callProcess "/sbin/upgradepkg"
            ["--reinstall", "--install-new", T.unpack old ++ fullPath]

buildFullPackageName :: PackageInfo -> String -> String -> String
buildFullPackageName pkg arch buildNumber
    = pkgname pkg ++ "-" ++ T.unpack (version pkg)
    ++ "-" ++ arch
    ++ "-" ++ buildNumber ++ "_dlack"

buildPackage :: PackageAction
buildPackage pkg old = do
    unameM' <- lift $ asks unameM
    let slackBuild = pkgname pkg <.> "SlackBuild"
    (buildNumber, arch) <- grepSlackBuild unameM' <$> liftIO (T.IO.readFile slackBuild)

    let fullPkgName = buildFullPackageName pkg arch buildNumber
    let pkgtoolsDb = "/var/lib/pkgtools/packages/" ++ fullPkgName

    alreadyInstalled <- liftIO $ doesFileExist pkgtoolsDb
    if alreadyInstalled
    then return ()
    else do
        liftIO $ console Info $ T.append "Building package " $ T.pack $ pkgname pkg

        downloadPackageSource pkg old

        loggingDirectory' <- lift $ asks loggingDirectory
        let logFile = loggingDirectory'
                  </> (pkgname pkg ++ "-" ++ T.unpack (version pkg) ++ ".log")
        code <- liftIO $ withSinkFile logFile $ \sink -> do
            let output = getZipSink $ ZipSink stdoutC *> ZipSink sink
            cp <- liftIO $ runSlackBuild slackBuild [("VERSION", T.unpack $ version pkg)]
            outErrProcess cp output

        case code of
            ExitSuccess -> installpkg old fullPkgName
            _ -> throwE $ PackageError (pkgname pkg) BuildError

installPackage :: PackageAction
installPackage pkg old = do
    let slackBuild = pkgname pkg <.> "SlackBuild"
    unameM' <- lift $ asks unameM
    (buildNumber, arch) <- grepSlackBuild unameM' <$> liftIO (T.IO.readFile slackBuild)

    installpkg old $ buildFullPackageName pkg arch buildNumber

downloadPackageSource :: PackageAction
downloadPackageSource pkg _ = do
    liftIO $ console Info $ T.append "Downloading the sources for " $ T.pack $ pkgname pkg

    downloadUrls
        <- let f (x, y) acc = case get x of
                (Just x') -> do
                    checksumOrE <- liftIO $ tryReadChecksum x
                    return $ case checksumOrE of
                        (Right checksum) | checksum == y -> acc
                        _ -> (x', y) : acc
                Nothing -> throwE $ PackageError (pkgname pkg) UnsupportedDownload
            in foldrM f [] $ zip (downloads pkg) (checksums pkg)

    caught <- liftIO $ tryDownload $ fst <$> downloadUrls
    sums <- either (throwE . PackageError (pkgname pkg) . DownloadError) return caught
    when (sums /= (snd <$> downloadUrls)) $ throwE $ PackageError (pkgname pkg) ChecksumMismatch

    where tryDownload :: [Req (Digest MD5)] -> IO (Either HttpException [Digest MD5])
          tryDownload = try . mapM (runReq defaultHttpConfig)
          tryReadChecksum :: T.Text -> IO (Either IOException (Digest MD5))
          tryReadChecksum = try . fmap md5sum . BSL.readFile . T.unpack . filename

doCompileOrder :: String -> Config.Config -> PackageAction -> String -> IO ()
doCompileOrder unameM' config action compileOrder = do
    content <- T.IO.readFile compileOrder

    packageList <- case parseCompileOrder compileOrder content of
      Right right -> return right
      Left left -> console Fatal (T.pack $ errorBundlePretty left) >> exitFailure

    maybeError <- foldlM packageAction (Right ()) packageList
    case maybeError of
      Left message -> console Fatal (showPackageError message) >> exitFailure
      Right () -> return ()

    where
        packageAction (Left x) = const $ return $ Left x
        packageAction _ = flip runReaderT (PackageEnvironment unameM' config)
                        . runExceptT
                        . doPackage action (takeDirectory compileOrder)

doPackage :: PackageAction
          -> FilePath
          -> Step
          -> ExceptT PackageError (ReaderT PackageEnvironment IO) ()
doPackage packageAction repo step = do
    oldDirectory <- liftIO getCurrentDirectory
    liftIO $ setCurrentDirectory $ repo </> T.unpack pkgName

    let infoFile = joinPath [repo, T.unpack pkgName, T.unpack pkgName <.> "info"]
    content <- liftIO $ C8.readFile infoFile

    pkg <- case parse parseInfoFile infoFile content of
        Left left -> throwE $ PackageError (T.unpack pkgName) $ ParseError left
        Right pkg -> return pkg

    packageAction pkg (fst exploded)

    liftIO $ setCurrentDirectory oldDirectory
    where
        explodePackageName (PackageName Nothing new) = ("", new)
        explodePackageName (PackageName (Just old) new) = (T.snoc old '%', new)
        exploded = explodePackageName step
        pkgName = snd exploded

readConfiguration :: IO Config.Config
readConfiguration = do
    let configPath = "etc/dlackware.yaml"
    configContent <- BSL.readFile configPath
    config <- case Config.parseConfig configPath configContent of
        Left x -> console Fatal x >> exitFailure
        Right x -> return x

    createDirectoryIfMissing True $ T.unpack $ Config.loggingDirectory config
    return config

collectRunInformation :: IO (String, Config.Config)
collectRunInformation = do
    config <- readConfiguration
    unameM' <- uname <$> readProcess "/usr/bin/uname" ["-m"] ""
    return (unameM', config)

getCompileOrders :: Config.Config -> [FilePath]
getCompileOrders config =
    let f x = T.unpack (Config.reposRoot config) </> T.unpack x
     in fmap f (Config.repos config)

build :: IO ()
build = do
    (unameM', config) <- collectRunInformation
    createDirectoryIfMissing False $ T.unpack $ Config.temporaryDirectory config

    let compileOrders = getCompileOrders config
     in mapM_ (doCompileOrder unameM' config buildPackage) compileOrders

downloadSource :: IO ()
downloadSource = do
    (unameM', config) <- collectRunInformation

    let compileOrders = getCompileOrders config
     in mapM_ (doCompileOrder unameM' config downloadPackageSource) compileOrders

install :: IO ()
install = do
    (unameM', config) <- collectRunInformation

    let compileOrders = getCompileOrders config
     in mapM_ (doCompileOrder unameM' config installPackage) compileOrders
