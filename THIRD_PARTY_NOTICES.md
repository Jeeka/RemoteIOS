# Third-party software

- FreeRDP, pinned by `freerdp.lock.json`: https://github.com/FreeRDP/FreeRDP — predominantly Apache License 2.0. The iOS client contains files under Mozilla Public License 2.0; retain the notices in those files. The source archive contains their license texts. MiptRDP changes to these files are distributed in `scripts/prepare.py` and `App/SceneDelegate.m`.
- OpenSSL: https://openssl-library.org/ — Apache License 2.0, version and download hash pinned by the selected FreeRDP source dependency configuration.
- cJSON: https://github.com/DaveGamble/cJSON — MIT License.
- uriparser: https://uriparser.github.io/ — New BSD License.

The build downloads these dependencies from the URLs and verifies the hashes supplied by the pinned FreeRDP dependency configurations. Preserve license notices when redistributing a compiled application.

The SceneDelegate replacement is derived from the FreeRDP iOS scene delegate, copyright 2013 Thincast Technologies GmbH, author Martin Fleisz, under MPL-2.0: https://www.mozilla.org/MPL/2.0/.
