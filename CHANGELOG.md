# Changelog

## [0.1.0](https://github.com/elixir-lang/expert/compare/v0.1.0...v0.1.0) (2025-11-27)


### ⚠ BREAKING CHANGES

* add CLI flag handling ([#185](https://github.com/elixir-lang/expert/issues/185))

### Features

* add CLI flag handling ([#185](https://github.com/elixir-lang/expert/issues/185)) ([46713a1](https://github.com/elixir-lang/expert/commit/46713a173b595f1bc2d1ce6e6f747a135291a392))
* epmdless clustering ([#205](https://github.com/elixir-lang/expert/issues/205)) ([488d3a9](https://github.com/elixir-lang/expert/commit/488d3a95e2c6eb2deb600ebf6cd5525232997b9b))
* epmdless deployments ([#167](https://github.com/elixir-lang/expert/issues/167)) ([9cfb5cc](https://github.com/elixir-lang/expert/commit/9cfb5cc57ea7458a7e67559e91332dd549b638fc))
* on the fly engine builds ([#24](https://github.com/elixir-lang/expert/issues/24)) ([51eb6f1](https://github.com/elixir-lang/expert/commit/51eb6f1523f7580e060fdc1d494872fb4909a0ee))


### Bug Fixes

* add lsp logging when failing to find an elixir executable ([#169](https://github.com/elixir-lang/expert/issues/169)) ([4dfba22](https://github.com/elixir-lang/expert/commit/4dfba220c97651c0f2c9eaf4b1c12d22c2055f37))
* better handling of native&lt;-&gt;lsp conversions ([#34](https://github.com/elixir-lang/expert/issues/34)) ([88dc456](https://github.com/elixir-lang/expert/commit/88dc4565c4069923ff958c6b7a6e541d45202806))
* bring back completions for things defined in test files ([#32](https://github.com/elixir-lang/expert/issues/32)) ([8d7a47a](https://github.com/elixir-lang/expert/commit/8d7a47af188d6e54213f704d977e25eff1150b5a))
* Crash when typing english ([#742](https://github.com/elixir-lang/expert/issues/742)) ([697eac9](https://github.com/elixir-lang/expert/commit/697eac93a6cc9e8e0cd3835504c72fcdf6208d0a)), closes [#741](https://github.com/elixir-lang/expert/issues/741)
* Current module not identified in defimpl ([#665](https://github.com/elixir-lang/expert/issues/665)) ([29f1055](https://github.com/elixir-lang/expert/commit/29f10553be303ad16918a14a4fcf96accd99e1e7))
* disable shell sessions when fetching the PATH ([#177](https://github.com/elixir-lang/expert/issues/177)) ([78236ef](https://github.com/elixir-lang/expert/commit/78236ef073c45222720c8e950e618a4289e81650))
* do not clamp character recvd from client ([#123](https://github.com/elixir-lang/expert/issues/123)) ([1a3b843](https://github.com/elixir-lang/expert/commit/1a3b843adb441da80e330d04702e3eda4d9d79ba))
* don't convert to_lsp twice in server specific messages ([#190](https://github.com/elixir-lang/expert/issues/190)) ([33bb850](https://github.com/elixir-lang/expert/commit/33bb85032e53f1adc70c67a7b518047d4f0d352e))
* don't sometimes hang ([5d6bcde](https://github.com/elixir-lang/expert/commit/5d6bcde857a2b318cf19168c7c4b6c8a4dddc63a))
* Edge case for module loading ([#738](https://github.com/elixir-lang/expert/issues/738)) ([dbbef2c](https://github.com/elixir-lang/expert/commit/dbbef2c48f655ecdfe116f157c2ffeb261083757))
* **engine:** handle failing build script ([#188](https://github.com/elixir-lang/expert/issues/188)) ([ce9ac22](https://github.com/elixir-lang/expert/commit/ce9ac22542379c8f8164f98213a3a34aad59544c))
* Erlang function calls in pipes were incorrectly formatted ([#476](https://github.com/elixir-lang/expert/issues/476)) ([92f1434](https://github.com/elixir-lang/expert/commit/92f1434537e6d753c28fe6a8014094ace33204e0)), closes [#475](https://github.com/elixir-lang/expert/issues/475)
* Exclude expert dependencies from completions based on project dependencies ([3a47058](https://github.com/elixir-lang/expert/commit/3a47058975610c9a480e05c4a6473966c8ddf2bf))
* fix release-all command ([492022f](https://github.com/elixir-lang/expert/commit/492022fc962feb3f34fbffce173331ead8700894))
* fixup namespacing and packaging ([#29](https://github.com/elixir-lang/expert/issues/29)) ([69ac8fe](https://github.com/elixir-lang/expert/commit/69ac8fe59469b273957746794873371d01c1673f))
* Function definition extractor chokes on macro functions ([#682](https://github.com/elixir-lang/expert/issues/682)) ([ccf355f](https://github.com/elixir-lang/expert/commit/ccf355f8ca53dab5fe86009d6c2ce687ad399476)), closes [#680](https://github.com/elixir-lang/expert/issues/680)
* give proper argument to `TaskQueue.add/2` in Server.handle_message ([#791](https://github.com/elixir-lang/expert/issues/791)) ([34ee071](https://github.com/elixir-lang/expert/commit/34ee0716681eb346bffba67ce77febc047189b61))
* handle string ids in requests ([#120](https://github.com/elixir-lang/expert/issues/120)) ([5d6bcde](https://github.com/elixir-lang/expert/commit/5d6bcde857a2b318cf19168c7c4b6c8a4dddc63a))
* include erlang source files when packaging engine ([580ccc8](https://github.com/elixir-lang/expert/commit/580ccc8c1241e6ae3f8eaf1687ed87d7ab3d1895))
* Invalid reads for requests that contain multi-byte characters ([#661](https://github.com/elixir-lang/expert/issues/661)) ([f6ca36f](https://github.com/elixir-lang/expert/commit/f6ca36f7b05302e73d76ee2b8b59fa87bfcf6a31))
* let the system figure out the elixir version for the project ([#162](https://github.com/elixir-lang/expert/issues/162)) ([5dacce4](https://github.com/elixir-lang/expert/commit/5dacce456cb111b75c3f1aeeba95b66e1bc07b04))
* make sure asdf shims are in the PATH ([#87](https://github.com/elixir-lang/expert/issues/87)) ([7626f90](https://github.com/elixir-lang/expert/commit/7626f90414c0078eaeda2e03d6aaa05f3383b25e))
* Module suggestion was incorrect for files with multiple periods ([#705](https://github.com/elixir-lang/expert/issues/705)) ([824df66](https://github.com/elixir-lang/expert/commit/824df66203cbd5b4e12846130a4f8dffe0199e3a)), closes [#703](https://github.com/elixir-lang/expert/issues/703)
* **nix:** use eval release command ([#199](https://github.com/elixir-lang/expert/issues/199)) ([25f80c8](https://github.com/elixir-lang/expert/commit/25f80c8e286ac20af5b0a6060795939c4a812859))
* Non-string test names crash exunit indexer ([#676](https://github.com/elixir-lang/expert/issues/676)) ([29373d5](https://github.com/elixir-lang/expert/commit/29373d5816ae161c4cdceb4cce9e8f1c99e065bc)), closes [#675](https://github.com/elixir-lang/expert/issues/675)
* properly set the mix env when building expert ([4caf258](https://github.com/elixir-lang/expert/commit/4caf2581ffa480aa87de70b6b9fef20207873414))
* remove erts from extra_applications ([#202](https://github.com/elixir-lang/expert/issues/202)) ([aa8bd84](https://github.com/elixir-lang/expert/commit/aa8bd84692222cfd763308815566d261430cd957))
* remove escape sequences from PATH in fish ([#237](https://github.com/elixir-lang/expert/issues/237)) ([b237fd5](https://github.com/elixir-lang/expert/commit/b237fd547a0bc3a34df2574b2d1c1fee47d1f2b6))
* Resolve doesn't recognize zero-arg defs as functions ([#606](https://github.com/elixir-lang/expert/issues/606)) ([38a649c](https://github.com/elixir-lang/expert/commit/38a649c7a6758c0c91dc350f0d7888a7b68017a6)), closes [#604](https://github.com/elixir-lang/expert/issues/604)
* revert "feat: epmdless deployments ([#167](https://github.com/elixir-lang/expert/issues/167))" ([#180](https://github.com/elixir-lang/expert/issues/180)) ([0f66faa](https://github.com/elixir-lang/expert/commit/0f66faa317fdbefd3aed407ce46c294d1f6bdec2))
* revert dev server ([#48](https://github.com/elixir-lang/expert/issues/48)) ([9345e31](https://github.com/elixir-lang/expert/commit/9345e31ea92da54c2124803223f8b50a08a53a00))
* stop sending genlsp datastructures to engine ([#31](https://github.com/elixir-lang/expert/issues/31)) ([43d406f](https://github.com/elixir-lang/expert/commit/43d406f6d46faa396269f1c7adb9ccda3e94fa29))
* Stutter when completing inside string interpolations ([#464](https://github.com/elixir-lang/expert/issues/464)) ([c73b0d0](https://github.com/elixir-lang/expert/commit/c73b0d0bf3896c3c8aa33c628d4bc1afea18aeb5)), closes [#462](https://github.com/elixir-lang/expert/issues/462)
* support Fish shell's space-separated PATH format ([#172](https://github.com/elixir-lang/expert/issues/172)) ([9803293](https://github.com/elixir-lang/expert/commit/9803293d4fe87ef1254b580b1e6aa0c833658edc))
* trim any quotes wrapping PATH when elixir is managed by mise ([#82](https://github.com/elixir-lang/expert/issues/82)) ([d828966](https://github.com/elixir-lang/expert/commit/d82896631c986ae57bdff47a8906c3d7bcbb22c5))
* trim PATH returned by shell ([#213](https://github.com/elixir-lang/expert/issues/213)) ([735199d](https://github.com/elixir-lang/expert/commit/735199deac03fa8a9de0a992964e9f14a1a35a66))
* update Nix derivation to use new build ([#344](https://github.com/elixir-lang/expert/issues/344)) ([3fa168d](https://github.com/elixir-lang/expert/commit/3fa168d2a6218435df49383489b6a2020372fa18))
* use correct build directory when namespacing expert ([b6540dd](https://github.com/elixir-lang/expert/commit/b6540ddffa210acd1ac03f9d7317f8baa3bcdc70))
* use dynamic registrations and start project node asynchronously ([#30](https://github.com/elixir-lang/expert/issues/30)) ([e1ce165](https://github.com/elixir-lang/expert/commit/e1ce1655e7354dae5206e42f4fc10f86ad347b90))
* use project directory when building engine ([#203](https://github.com/elixir-lang/expert/issues/203)) ([c5ac441](https://github.com/elixir-lang/expert/commit/c5ac44164b69b0ec63d5f5b462c40ba787d9fe90))
* utf8_prefix should take into account empty lines ([#164](https://github.com/elixir-lang/expert/issues/164)) ([16c21e0](https://github.com/elixir-lang/expert/commit/16c21e087b1d6753e7fa46c13c67242c69a48e31))


### Miscellaneous Chores

* release as 0.1.0 ([7625d3c](https://github.com/elixir-lang/expert/commit/7625d3cb530897c02657837fad2b4116228346e9))

## Unreleased
No changes yet
