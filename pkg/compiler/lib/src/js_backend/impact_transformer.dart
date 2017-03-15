// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library js_backend.backend.impact_transformer;

import '../common.dart';
import '../common_elements.dart';
import '../common/backend_api.dart' show ImpactTransformer;
import '../common/codegen.dart' show CodegenImpact;
import '../common/resolution.dart' show Resolution, ResolutionImpact;
import '../constants/expressions.dart';
import '../constants/values.dart';
import '../common_elements.dart' show ElementEnvironment;
import '../elements/elements.dart';
import '../elements/resolution_types.dart';
import '../enqueue.dart' show ResolutionEnqueuer;
import '../native/enqueue.dart';
import '../native/native.dart' as native;
import '../options.dart';
import '../universe/feature.dart';
import '../universe/use.dart'
    show ConstantUse, StaticUse, StaticUseKind, TypeUse, TypeUseKind;
import '../universe/world_impact.dart' show TransformedWorldImpact, WorldImpact;
import '../util/util.dart';
import 'backend.dart';
import 'backend_helpers.dart';
import 'backend_impact.dart';
import 'backend_usage.dart';
import 'checked_mode_helpers.dart';
import 'custom_elements_analysis.dart';
import 'interceptor_data.dart';
import 'lookup_map_analysis.dart';
import 'mirrors_data.dart';
import 'namer.dart';
import 'native_data.dart';

class JavaScriptImpactTransformer extends ImpactTransformer {
  final CompilerOptions _options;
  final Resolution _resolution;
  final ElementEnvironment _elementEnvironment;
  final CommonElements _commonElements;
  final BackendImpacts _impacts;
  final NativeClassData _nativeClassData;
  final NativeResolutionEnqueuer _nativeResolutionEnqueuer;
  final BackendUsageBuilder _backendUsageBuider;
  final MirrorsData _mirrorsData;
  final CustomElementsResolutionAnalysis _customElementsResolutionAnalysis;
  final RuntimeTypesNeedBuilder _rtiNeedBuilder;

  JavaScriptImpactTransformer(
      this._options,
      this._resolution,
      this._elementEnvironment,
      this._commonElements,
      this._impacts,
      this._nativeClassData,
      this._nativeResolutionEnqueuer,
      this._backendUsageBuider,
      this._mirrorsData,
      this._customElementsResolutionAnalysis,
      this._rtiNeedBuilder);

  @override
  WorldImpact transformResolutionImpact(
      ResolutionEnqueuer enqueuer, ResolutionImpact worldImpact) {
    TransformedWorldImpact transformed =
        new TransformedWorldImpact(worldImpact);

    void registerImpact(BackendImpact impact) {
      impact.registerImpact(transformed, _elementEnvironment);
      _backendUsageBuider.processBackendImpact(impact);
    }

    for (Feature feature in worldImpact.features) {
      switch (feature) {
        case Feature.ABSTRACT_CLASS_INSTANTIATION:
          registerImpact(_impacts.abstractClassInstantiation);
          break;
        case Feature.ASSERT:
          registerImpact(_impacts.assertWithoutMessage);
          break;
        case Feature.ASSERT_WITH_MESSAGE:
          registerImpact(_impacts.assertWithMessage);
          break;
        case Feature.ASYNC:
          registerImpact(_impacts.asyncBody);
          break;
        case Feature.ASYNC_FOR_IN:
          registerImpact(_impacts.asyncForIn);
          break;
        case Feature.ASYNC_STAR:
          registerImpact(_impacts.asyncStarBody);
          break;
        case Feature.CATCH_STATEMENT:
          registerImpact(_impacts.catchStatement);
          break;
        case Feature.COMPILE_TIME_ERROR:
          if (_options.generateCodeWithCompileTimeErrors) {
            // TODO(johnniwinther): This should have its own uncatchable error.
            registerImpact(_impacts.throwRuntimeError);
          }
          break;
        case Feature.FALL_THROUGH_ERROR:
          registerImpact(_impacts.fallThroughError);
          break;
        case Feature.FIELD_WITHOUT_INITIALIZER:
        case Feature.LOCAL_WITHOUT_INITIALIZER:
          transformed.registerTypeUse(
              new TypeUse.instantiation(_commonElements.nullType));
          registerImpact(_impacts.nullLiteral);
          break;
        case Feature.LAZY_FIELD:
          registerImpact(_impacts.lazyField);
          break;
        case Feature.STACK_TRACE_IN_CATCH:
          registerImpact(_impacts.stackTraceInCatch);
          break;
        case Feature.STRING_INTERPOLATION:
          registerImpact(_impacts.stringInterpolation);
          break;
        case Feature.STRING_JUXTAPOSITION:
          registerImpact(_impacts.stringJuxtaposition);
          break;
        case Feature.SUPER_NO_SUCH_METHOD:
          registerImpact(_impacts.superNoSuchMethod);
          break;
        case Feature.SYMBOL_CONSTRUCTOR:
          registerImpact(_impacts.symbolConstructor);
          break;
        case Feature.SYNC_FOR_IN:
          registerImpact(_impacts.syncForIn);
          break;
        case Feature.SYNC_STAR:
          registerImpact(_impacts.syncStarBody);
          break;
        case Feature.THROW_EXPRESSION:
          registerImpact(_impacts.throwExpression);
          break;
        case Feature.THROW_NO_SUCH_METHOD:
          registerImpact(_impacts.throwNoSuchMethod);
          break;
        case Feature.THROW_RUNTIME_ERROR:
          registerImpact(_impacts.throwRuntimeError);
          break;
        case Feature.TYPE_VARIABLE_BOUNDS_CHECK:
          registerImpact(_impacts.typeVariableBoundCheck);
          break;
      }
    }

    bool hasAsCast = false;
    bool hasTypeLiteral = false;
    for (TypeUse typeUse in worldImpact.typeUses) {
      ResolutionDartType type = typeUse.type;
      switch (typeUse.kind) {
        case TypeUseKind.INSTANTIATION:
        case TypeUseKind.MIRROR_INSTANTIATION:
        case TypeUseKind.NATIVE_INSTANTIATION:
          registerRequiredType(type);
          break;
        case TypeUseKind.IS_CHECK:
          onIsCheck(type, transformed);
          break;
        case TypeUseKind.AS_CAST:
          onIsCheck(type, transformed);
          hasAsCast = true;
          break;
        case TypeUseKind.CHECKED_MODE_CHECK:
          if (_options.enableTypeAssertions) {
            onIsCheck(type, transformed);
          }
          break;
        case TypeUseKind.CATCH_TYPE:
          onIsCheck(type, transformed);
          break;
        case TypeUseKind.TYPE_LITERAL:
          _customElementsResolutionAnalysis.registerTypeLiteral(type);
          if (type.isTypeVariable && type is! MethodTypeVariableType) {
            // GENERIC_METHODS: The `is!` test above filters away method type
            // variables, because they have the value `dynamic` with the
            // incomplete support for generic methods offered with
            // '--generic-method-syntax'. This must be revised in order to
            // support generic methods fully.
            ClassElement cls = type.element.enclosingClass;
            _rtiNeedBuilder.registerClassUsingTypeVariableExpression(cls);
            registerImpact(_impacts.typeVariableExpression);
          }
          hasTypeLiteral = true;
          break;
      }
    }

    if (hasAsCast) {
      registerImpact(_impacts.asCheck);
    }

    if (hasTypeLiteral) {
      transformed
          .registerTypeUse(new TypeUse.instantiation(_commonElements.typeType));
      registerImpact(_impacts.typeLiteral);
    }

    for (MapLiteralUse mapLiteralUse in worldImpact.mapLiterals) {
      // TODO(johnniwinther): Use the [isEmpty] property when factory
      // constructors are registered directly.
      if (mapLiteralUse.isConstant) {
        registerImpact(_impacts.constantMapLiteral);
      } else {
        transformed
            .registerTypeUse(new TypeUse.instantiation(mapLiteralUse.type));
      }
      ResolutionInterfaceType type = mapLiteralUse.type;
      registerRequiredType(type);
    }

    for (ListLiteralUse listLiteralUse in worldImpact.listLiterals) {
      // TODO(johnniwinther): Use the [isConstant] and [isEmpty] property when
      // factory constructors are registered directly.
      transformed
          .registerTypeUse(new TypeUse.instantiation(listLiteralUse.type));
      ResolutionInterfaceType type = listLiteralUse.type;
      registerRequiredType(type);
    }

    if (worldImpact.constSymbolNames.isNotEmpty) {
      registerImpact(_impacts.constSymbol);
      for (String constSymbolName in worldImpact.constSymbolNames) {
        _mirrorsData.registerConstSymbol(constSymbolName);
      }
    }

    for (StaticUse staticUse in worldImpact.staticUses) {
      switch (staticUse.kind) {
        case StaticUseKind.CLOSURE:
          registerImpact(_impacts.closure);
          LocalFunctionElement closure = staticUse.element;
          if (closure.type.containsTypeVariables) {
            registerImpact(_impacts.computeSignature);
          }
          break;
        case StaticUseKind.CONST_CONSTRUCTOR_INVOKE:
        case StaticUseKind.CONSTRUCTOR_INVOKE:
          registerRequiredType(staticUse.type);
          break;
        default:
      }
    }

    for (ConstantExpression constant in worldImpact.constantLiterals) {
      switch (constant.kind) {
        case ConstantExpressionKind.NULL:
          registerImpact(_impacts.nullLiteral);
          break;
        case ConstantExpressionKind.BOOL:
          registerImpact(_impacts.boolLiteral);
          break;
        case ConstantExpressionKind.INT:
          registerImpact(_impacts.intLiteral);
          break;
        case ConstantExpressionKind.DOUBLE:
          registerImpact(_impacts.doubleLiteral);
          break;
        case ConstantExpressionKind.STRING:
          registerImpact(_impacts.stringLiteral);
          break;
        default:
          assert(invariant(NO_LOCATION_SPANNABLE, false,
              message: "Unexpected constant literal: ${constant.kind}."));
      }
    }

    for (native.NativeBehavior behavior in worldImpact.nativeData) {
      _nativeResolutionEnqueuer.registerNativeBehavior(
          transformed, behavior, worldImpact);
    }

    return transformed;
  }

  /// Register [type] as required for the runtime type information system.
  void registerRequiredType(ResolutionDartType type) {
    if (!type.isInterfaceType) return;
    // If [argument] has type variables or is a type variable, this method
    // registers a RTI dependency between the class where the type variable is
    // defined (that is the enclosing class of the current element being
    // resolved) and the class of [type]. If the class of [type] requires RTI,
    // then the class of the type variable does too.
    ClassElement contextClass = Types.getClassContext(type);
    if (contextClass != null) {
      _rtiNeedBuilder.registerRtiDependency(type.element, contextClass);
    }
  }

  // TODO(johnniwinther): Maybe split this into [onAssertType] and [onTestType].
  void onIsCheck(ResolutionDartType type, TransformedWorldImpact transformed) {
    void registerImpact(BackendImpact impact) {
      impact.registerImpact(transformed, _elementEnvironment);
      _backendUsageBuider.processBackendImpact(impact);
    }

    registerRequiredType(type);
    type.computeUnaliased(_resolution);
    type = type.unaliased;
    registerImpact(_impacts.typeCheck);

    bool inCheckedMode = _options.enableTypeAssertions;
    if (inCheckedMode) {
      registerImpact(_impacts.checkedModeTypeCheck);
    }
    if (type.isMalformed) {
      registerImpact(_impacts.malformedTypeCheck);
    }
    if (!type.treatAsRaw || type.containsTypeVariables || type.isFunctionType) {
      registerImpact(_impacts.genericTypeCheck);
      if (inCheckedMode) {
        registerImpact(_impacts.genericCheckedModeTypeCheck);
      }
      if (type.isTypeVariable) {
        registerImpact(_impacts.typeVariableTypeCheck);
        if (inCheckedMode) {
          registerImpact(_impacts.typeVariableCheckedModeTypeCheck);
        }
      }
    }
    if (type is ResolutionFunctionType) {
      registerImpact(_impacts.functionTypeCheck);
    }
    if (type is ResolutionInterfaceType &&
        _nativeClassData.isNativeClass(type.element)) {
      registerImpact(_impacts.nativeTypeCheck);
    }
  }
}

class CodegenImpactTransformer {
  final CompilerOptions _options;
  final ElementEnvironment _elementEnvironment;
  final BackendHelpers _helpers;
  final BackendImpacts _impacts;
  final CheckedModeHelpers _checkedModeHelpers;
  final NativeData _nativeData;
  final BackendUsage _backendUsage;
  final RuntimeTypesNeed _rtiNeed;
  final NativeCodegenEnqueuer _nativeCodegenEnqueuer;
  final Namer _namer;
  final MirrorsData _mirrorsData;
  final OneShotInterceptorData _oneShotInterceptorData;
  final LookupMapAnalysis _lookupMapAnalysis;
  final RuntimeTypesChecksBuilder _rtiChecksBuilder;

  CodegenImpactTransformer(
      this._options,
      this._elementEnvironment,
      this._helpers,
      this._impacts,
      this._checkedModeHelpers,
      this._nativeData,
      this._backendUsage,
      this._rtiNeed,
      this._nativeCodegenEnqueuer,
      this._namer,
      this._mirrorsData,
      this._oneShotInterceptorData,
      this._lookupMapAnalysis,
      this._rtiChecksBuilder);

  void onIsCheckForCodegen(
      ResolutionDartType type, TransformedWorldImpact transformed) {
    if (type.isDynamic) return;
    type = type.unaliased;
    _impacts.typeCheck.registerImpact(transformed, _elementEnvironment);

    bool inCheckedMode = _options.enableTypeAssertions;
    // [registerIsCheck] is also called for checked mode checks, so we
    // need to register checked mode helpers.
    if (inCheckedMode) {
      // All helpers are added to resolution queue in enqueueHelpers. These
      // calls to [enqueue] with the resolution enqueuer serve as assertions
      // that the helper was in fact added.
      // TODO(13155): Find a way to enqueue helpers lazily.
      CheckedModeHelper helper =
          _checkedModeHelpers.getCheckedModeHelper(type, typeCast: false);
      if (helper != null) {
        StaticUse staticUse = helper.getStaticUse(_helpers);
        transformed.registerStaticUse(staticUse);
      }
      // We also need the native variant of the check (for DOM types).
      helper =
          _checkedModeHelpers.getNativeCheckedModeHelper(type, typeCast: false);
      if (helper != null) {
        StaticUse staticUse = helper.getStaticUse(_helpers);
        transformed.registerStaticUse(staticUse);
      }
    }
    if (!type.treatAsRaw || type.containsTypeVariables) {
      _impacts.genericIsCheck.registerImpact(transformed, _elementEnvironment);
    }
    if (type is ResolutionInterfaceType &&
        _nativeData.isNativeClass(type.element)) {
      // We will neeed to add the "$is" and "$as" properties on the
      // JavaScript object prototype, so we make sure
      // [:defineProperty:] is compiled.
      _impacts.nativeTypeCheck.registerImpact(transformed, _elementEnvironment);
    }
  }

  WorldImpact transformCodegenImpact(CodegenImpact impact) {
    TransformedWorldImpact transformed = new TransformedWorldImpact(impact);

    for (TypeUse typeUse in impact.typeUses) {
      ResolutionDartType type = typeUse.type;
      switch (typeUse.kind) {
        case TypeUseKind.INSTANTIATION:
          _lookupMapAnalysis.registerInstantiatedType(type);
          break;
        case TypeUseKind.IS_CHECK:
          onIsCheckForCodegen(type, transformed);
          break;
        default:
      }
    }

    for (Pair<ResolutionDartType, ResolutionDartType> check
        in impact.typeVariableBoundsSubtypeChecks) {
      _rtiChecksBuilder.registerTypeVariableBoundsSubtypeCheck(
          check.a, check.b);
    }

    for (StaticUse staticUse in impact.staticUses) {
      switch (staticUse.kind) {
        case StaticUseKind.CLOSURE:
          LocalFunctionElement closure = staticUse.element;
          if (_rtiNeed.localFunctionNeedsRti(closure)) {
            _impacts.computeSignature
                .registerImpact(transformed, _elementEnvironment);
          }
          break;
        case StaticUseKind.CONST_CONSTRUCTOR_INVOKE:
        case StaticUseKind.CONSTRUCTOR_INVOKE:
          _lookupMapAnalysis.registerInstantiatedType(staticUse.type);
          break;
        default:
      }
    }

    for (String name in impact.constSymbols) {
      _mirrorsData.registerConstSymbol(name);
    }

    for (Set<ClassElement> classes in impact.specializedGetInterceptors) {
      _oneShotInterceptorData.registerSpecializedGetInterceptor(
          classes, _namer);
    }

    if (impact.usesInterceptor) {
      if (_nativeCodegenEnqueuer.hasInstantiatedNativeClasses) {
        _impacts.interceptorUse
            .registerImpact(transformed, _elementEnvironment);
        // TODO(johnniwinther): Avoid these workarounds.
        _backendUsage.needToInitializeIsolateAffinityTag = true;
        _backendUsage.needToInitializeDispatchProperty = true;
      }
    }

    for (FunctionElement element in impact.asyncMarkers) {
      switch (element.asyncMarker) {
        case AsyncMarker.ASYNC:
          _impacts.asyncBody.registerImpact(transformed, _elementEnvironment);
          break;
        case AsyncMarker.SYNC_STAR:
          _impacts.syncStarBody
              .registerImpact(transformed, _elementEnvironment);
          break;
        case AsyncMarker.ASYNC_STAR:
          _impacts.asyncStarBody
              .registerImpact(transformed, _elementEnvironment);
          break;
      }
    }

    // TODO(johnniwinther): Remove eager registration.
    return transformed;
  }
}