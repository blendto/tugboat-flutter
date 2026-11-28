# Repository migration

The GitHub repository is now `blendto/tugboat-mobile-sdk`;
`https://github.com/blendto/tugboat-flutter` redirects to it. The local tree
uses the `tugboat-mobile` layout.

After a repository rename:

1. Confirm the old URL redirects.
2. Update `origin` to the new URL.
3. Confirm fetch and push.
4. Replace remaining old-name URLs in pubspecs, podspecs, badges, and docs
   except where compatibility requires the old name.

Publishing coordinates and Dart package names do not change with the
repository name. The directory rename is not a package rename.

npm checks the repository name for `@tugboat-ai/react-native`: after any
rename, update `repository.url` in `sdks/react-native/package.json` and the
package's trusted publisher on npmjs.com before the next release, or the
publish fails.
