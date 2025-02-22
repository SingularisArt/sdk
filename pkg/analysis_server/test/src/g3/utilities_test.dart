// Copyright (c) 2023, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/g3/utilities.dart';
import 'package:dart_style/dart_style.dart';
import 'package:test/test.dart';

void main() {
  group('format', () {
    test('pass', () {
      var contents = '''
void f(int m){
if (m > 3){
print(3);
}else {
print(0);
}
}
''';
      var formattedContents = '''
void f(int m) {
  if (m > 3) {
    print(3);
  } else {
    print(0);
  }
}
''';
      var result = format(contents);
      expect(result, formattedContents);
    });

    test('fail', () {
      var contents = '''
void f(){
var x
}
''';
      try {
        format(contents);
      } catch (e) {
        expect(e.runtimeType, FormatterException);
      }
    });
  });

  group('organize imports', () {
    test('pass', () {
      var contents = '''
import 'dart:io';
import 'dart:async';

Future a;
''';

      var sortedContents = '''
import 'dart:async';
import 'dart:io';

Future a;
''';

      var result = sortDirectives(contents);
      expect(result.content, sortedContents);
      expect(result.errors.isEmpty, true);
    });

    test('fail', () {
      var contents = '''
import 'dart:io'
import 'dart:async';

Future a;
''';
      var result = sortDirectives(contents);
      expect(result.content, contents);
      expect(result.errors.length, 1);
    });
  });
}
