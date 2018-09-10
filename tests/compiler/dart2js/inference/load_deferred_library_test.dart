// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:async_helper/async_helper.dart';
import 'package:compiler/src/commandline_options.dart';
import 'package:compiler/src/common_elements.dart';
import 'package:compiler/src/common/names.dart';
import 'package:compiler/src/compiler.dart';
import 'package:compiler/src/elements/entities.dart';
import 'package:compiler/src/inferrer/typemasks/masks.dart';
import 'package:compiler/src/js_model/js_strategy.dart';
import 'package:compiler/src/kernel/element_map.dart';
import 'package:compiler/src/types/abstract_value_domain.dart';
import 'package:compiler/src/world.dart';
import 'package:expect/expect.dart';
import 'package:kernel/ast.dart' as ir;
import '../helpers/memory_compiler.dart';

const String source = '''
import 'package:expect/expect.dart' deferred as expect;

main() {
  callLoadLibrary();
}

callLoadLibrary() => expect.loadLibrary();
''';

main() async {
  asyncTest(() async {
    print('--test Dart 2 ----------------------------------------------------');
    await runTest([], trust: false);
    print('--test Dart 2 --omit-implicit-checks -----------------------------');
    await runTest([Flags.omitImplicitChecks]);
  });
}

runTest(List<String> options, {bool trust: true}) async {
  CompilationResult result = await runCompiler(
      memorySourceFiles: {'main.dart': source}, options: options);
  Expect.isTrue(result.isSuccess);
  Compiler compiler = result.compiler;
  JClosedWorld closedWorld = compiler.backendClosedWorldForTesting;
  AbstractValueDomain abstractValueDomain = closedWorld.abstractValueDomain;
  ElementEnvironment elementEnvironment = closedWorld.elementEnvironment;
  LibraryEntity helperLibrary =
      elementEnvironment.lookupLibrary(Uris.dart__js_helper);
  FunctionEntity loadDeferredLibrary = elementEnvironment.lookupLibraryMember(
      helperLibrary, 'loadDeferredLibrary');
  TypeMask typeMask;

  JsBackendStrategy backendStrategy = compiler.backendStrategy;
  KernelToLocalsMap localsMap = backendStrategy.globalLocalsMapForTesting
      .getLocalsMap(loadDeferredLibrary);
  MemberDefinition definition =
      backendStrategy.elementMap.getMemberDefinition(loadDeferredLibrary);
  ir.Procedure procedure = definition.node;
  typeMask = compiler.globalInference.resultsForTesting.resultOfParameter(
      localsMap
          .getLocalVariable(procedure.function.positionalParameters.first));

  if (trust) {
    Expect.equals(
        abstractValueDomain.includeNull(abstractValueDomain.stringType),
        typeMask);
  } else {
    Expect.equals(abstractValueDomain.dynamicType, typeMask);
  }
}
