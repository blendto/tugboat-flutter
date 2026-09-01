# Repository migration

The GitHub repository is still `blendto/tugboat-flutter`. The local tree
already uses the `tugboat-mobile` layout.

When an administrator renames the GitHub repository to `tugboat-mobile`:

1. Confirm `https://github.com/blendto/tugboat-flutter` redirects.
2. Update `origin` to the new URL.
3. Confirm fetch and push.
4. Replace remaining `tugboat-flutter` URLs in pubspecs, badges, and docs
   except where compatibility requires the old name.

Until that rename, keep publishing coordinates and Dart package names as
documented. The directory rename is not a package rename.
