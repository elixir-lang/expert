# Changelog

## [0.2.0](https://github.com/elixir-lang/expert/compare/v0.1.0...v0.2.0) (2025-09-07)


### Features

* on the fly engine builds ([#24](https://github.com/elixir-lang/expert/issues/24)) ([51eb6f1](https://github.com/elixir-lang/expert/commit/51eb6f1523f7580e060fdc1d494872fb4909a0ee))


### Bug Fixes

* Add missing command to get rtx env ([#281](https://github.com/elixir-lang/expert/issues/281)) ([5ed61fa](https://github.com/elixir-lang/expert/commit/5ed61fac5ddaf72e0781d883eae26fc0d4ef4c1c))
* Argument names crashes in light of a literal atom ([#285](https://github.com/elixir-lang/expert/issues/285)) ([185152d](https://github.com/elixir-lang/expert/commit/185152d56f9a357bd98e704de3bd2c752f3db0ee))
* better handling of native&lt;-&gt;lsp conversions ([#34](https://github.com/elixir-lang/expert/issues/34)) ([88dc456](https://github.com/elixir-lang/expert/commit/88dc4565c4069923ff958c6b7a6e541d45202806))
* bring back completions for things defined in test files ([#32](https://github.com/elixir-lang/expert/issues/32)) ([8d7a47a](https://github.com/elixir-lang/expert/commit/8d7a47af188d6e54213f704d977e25eff1150b5a))
* Crash when typing english ([#742](https://github.com/elixir-lang/expert/issues/742)) ([697eac9](https://github.com/elixir-lang/expert/commit/697eac93a6cc9e8e0cd3835504c72fcdf6208d0a)), closes [#741](https://github.com/elixir-lang/expert/issues/741)
* Current module not identified in defimpl ([#665](https://github.com/elixir-lang/expert/issues/665)) ([29f1055](https://github.com/elixir-lang/expert/commit/29f10553be303ad16918a14a4fcf96accd99e1e7))
* don't sometimes hang ([5d6bcde](https://github.com/elixir-lang/expert/commit/5d6bcde857a2b318cf19168c7c4b6c8a4dddc63a))
* Edge case for module loading ([#738](https://github.com/elixir-lang/expert/issues/738)) ([dbbef2c](https://github.com/elixir-lang/expert/commit/dbbef2c48f655ecdfe116f157c2ffeb261083757))
* Erlang function calls in pipes were incorrectly formatted ([#476](https://github.com/elixir-lang/expert/issues/476)) ([92f1434](https://github.com/elixir-lang/expert/commit/92f1434537e6d753c28fe6a8014094ace33204e0)), closes [#475](https://github.com/elixir-lang/expert/issues/475)
* Exclude expert dependencies from completions based on project dependencies ([3a47058](https://github.com/elixir-lang/expert/commit/3a47058975610c9a480e05c4a6473966c8ddf2bf))
* fix release-all command ([492022f](https://github.com/elixir-lang/expert/commit/492022fc962feb3f34fbffce173331ead8700894))
* fixup namespacing and packaging ([#29](https://github.com/elixir-lang/expert/issues/29)) ([69ac8fe](https://github.com/elixir-lang/expert/commit/69ac8fe59469b273957746794873371d01c1673f))
* Function definition extractor chokes on macro functions ([#682](https://github.com/elixir-lang/expert/issues/682)) ([ccf355f](https://github.com/elixir-lang/expert/commit/ccf355f8ca53dab5fe86009d6c2ce687ad399476)), closes [#680](https://github.com/elixir-lang/expert/issues/680)
* give proper argument to `TaskQueue.add/2` in Server.handle_message ([#791](https://github.com/elixir-lang/expert/issues/791)) ([34ee071](https://github.com/elixir-lang/expert/commit/34ee0716681eb346bffba67ce77febc047189b61))
* handle string ids in requests ([#120](https://github.com/elixir-lang/expert/issues/120)) ([5d6bcde](https://github.com/elixir-lang/expert/commit/5d6bcde857a2b318cf19168c7c4b6c8a4dddc63a))
* include erlang source files when packaging engine ([580ccc8](https://github.com/elixir-lang/expert/commit/580ccc8c1241e6ae3f8eaf1687ed87d7ab3d1895))
* Invalid reads for requests that contain multi-byte characters ([#661](https://github.com/elixir-lang/expert/issues/661)) ([f6ca36f](https://github.com/elixir-lang/expert/commit/f6ca36f7b05302e73d76ee2b8b59fa87bfcf6a31))
* make sure asdf shims are in the PATH ([#87](https://github.com/elixir-lang/expert/issues/87)) ([7626f90](https://github.com/elixir-lang/expert/commit/7626f90414c0078eaeda2e03d6aaa05f3383b25e))
* Module suggestion was incorrect for files with multiple periods ([#705](https://github.com/elixir-lang/expert/issues/705)) ([824df66](https://github.com/elixir-lang/expert/commit/824df66203cbd5b4e12846130a4f8dffe0199e3a)), closes [#703](https://github.com/elixir-lang/expert/issues/703)
* Non-string test names crash exunit indexer ([#676](https://github.com/elixir-lang/expert/issues/676)) ([29373d5](https://github.com/elixir-lang/expert/commit/29373d5816ae161c4cdceb4cce9e8f1c99e065bc)), closes [#675](https://github.com/elixir-lang/expert/issues/675)
* properly set the mix env when building expert ([4caf258](https://github.com/elixir-lang/expert/commit/4caf2581ffa480aa87de70b6b9fef20207873414))
* Resolve doesn't recognize zero-arg defs as functions ([#606](https://github.com/elixir-lang/expert/issues/606)) ([38a649c](https://github.com/elixir-lang/expert/commit/38a649c7a6758c0c91dc350f0d7888a7b68017a6)), closes [#604](https://github.com/elixir-lang/expert/issues/604)
* revert dev server ([#48](https://github.com/elixir-lang/expert/issues/48)) ([9345e31](https://github.com/elixir-lang/expert/commit/9345e31ea92da54c2124803223f8b50a08a53a00))
* stop sending genlsp datastructures to engine ([#31](https://github.com/elixir-lang/expert/issues/31)) ([43d406f](https://github.com/elixir-lang/expert/commit/43d406f6d46faa396269f1c7adb9ccda3e94fa29))
* Stutter when completing inside string interpolations ([#464](https://github.com/elixir-lang/expert/issues/464)) ([c73b0d0](https://github.com/elixir-lang/expert/commit/c73b0d0bf3896c3c8aa33c628d4bc1afea18aeb5)), closes [#462](https://github.com/elixir-lang/expert/issues/462)
* trim any quotes wrapping PATH when elixir is managed by mise ([#82](https://github.com/elixir-lang/expert/issues/82)) ([d828966](https://github.com/elixir-lang/expert/commit/d82896631c986ae57bdff47a8906c3d7bcbb22c5))
* update Nix derivation to use new build ([#344](https://github.com/elixir-lang/expert/issues/344)) ([3fa168d](https://github.com/elixir-lang/expert/commit/3fa168d2a6218435df49383489b6a2020372fa18))
* use correct build directory when namespacing expert ([b6540dd](https://github.com/elixir-lang/expert/commit/b6540ddffa210acd1ac03f9d7317f8baa3bcdc70))
* use dynamic registrations and start project node asynchronously ([#30](https://github.com/elixir-lang/expert/issues/30)) ([e1ce165](https://github.com/elixir-lang/expert/commit/e1ce1655e7354dae5206e42f4fc10f86ad347b90))

## Unreleased
No changes yet
