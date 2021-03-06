# Dlackware Gnome build system and installer

[![Build Status](https://semaphoreci.com/api/v1/belka-ew/dlackware/branches/master/badge.svg)](https://semaphoreci.com/belka-ew/dlackware)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](https://choosealicense.com/licenses/gpl-3.0/)

This is the build system used to build systemd and Dlackware Gnome distribution
for Slackware Linux.

This repository doesn't contain any packages, please refer to another
repositories in the Dlackware organization if you are looking for packages.

## Build and install Dlackware build system

1. Install Haskell stack:

```shell
wget -qO- https://get.haskellstack.org/ | sh
```

2. Clone this repository:

```shell
git clone https://github.com/Dlackware/dlackware.git
```

3. Then switch to the cloned directory:

```shell
cd dlackware
```

4. Build the build system:

```shell
stack build
```

It will take some time to download the dependencies on first run.

5. After that you can run the build system with:

```shell
stack exec dlackware -- …
```

Just replace `…` with the arguments that should be passed to the build system.
You can get a list of supported commands and command line arguments with:

```shell
stack exec dlackware -- --help
```

## Configuration

The configuration is described by a YAML file, that should be in
`./etc/dlackware.yaml`.

Sample configuratin can be found in `./etc/dlackware.yaml.new`. Just copy this
file to `./etc/dlackware.yaml` and change as appropriate.

The configuration is very simple and all options can be found in the sample
configuration file mentioned above.

- `reposRoot` specifies the root directory used to find the packages to be
  built.
- `loggingDirectory` is the directory there the build system writes its log
  files, one file per built package.
- `temporaryDirectory` is the directory used to build the actual software. This
  directory should have enough free space to be able to build large projects,
  like Gnome.
- `repos` is a list of directories (relative to `reposRoot`) that contain
  `compile-order` files, text files with a list of packages in the order these
  should be built. Dlackware doesn't look into the directory structure to find
  the packages; only the packages mentioned in `compile-order`s are built.

## Running the tests

```shell
stack test --pedantic

stack build hlint
stack exec hlint -- src test
```
