import 'package:flutter/foundation.dart';

/// Puts the licences of the sticker art into the list the system shows (`showLicensePage`), as the licences of the
/// packages are.
void registerStickerLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(['Noto Animated Emoji'], _notoNotice);
    yield const LicenseEntryWithLineBreaks(['Fluent Emoji'], _fluentLicense);
  });
}

const _notoNotice = '''
Noto Animated Emoji, by Google.
https://googlefonts.github.io/noto-emoji-animation/

Licensed under the Creative Commons Attribution 4.0 International License (CC BY 4.0).
https://creativecommons.org/licenses/by/4.0/

You may share and adapt the material for any purpose, even commercially, as long as you give appropriate credit,
provide a link to the licence and indicate if changes were made. The animations here were converted to animated WebP
and scaled; they are otherwise as Google made them.''';

const _fluentLicense = '''
Fluent Emoji, by Microsoft.
https://github.com/microsoft/fluentui-emoji

MIT License

Copyright (c) Microsoft Corporation.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.''';
