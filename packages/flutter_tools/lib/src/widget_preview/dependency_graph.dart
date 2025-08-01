// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// @docImport 'preview_detector.dart';
library;

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element2.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/error/error.dart';

import '../base/logger.dart';
import 'preview_details.dart';
import 'utils.dart';

/// A path / URI pair used to map previews to a file.
///
/// We don't just use a path or a URI as the file watcher doesn't report URIs
/// (e.g., package:*) but the analyzer APIs do, and the code generator emits
/// package URIs for preview imports.
typedef PreviewPath = ({String path, Uri uri});

/// A mapping of file / library paths to dependency graph nodes containing details related to
/// previews defined within the file / library.
typedef PreviewDependencyGraph = Map<PreviewPath, LibraryPreviewNode>;

/// Visitor which detects previews and extracts [PreviewDetails] for later code
/// generation.
class _PreviewVisitor extends RecursiveAstVisitor<void> {
  _PreviewVisitor({required LibraryElement2 lib})
    : packageName = lib.uri.scheme == 'package' ? lib.uri.pathSegments.first : null,
      _context = lib.session.analysisContext;

  late final String? packageName;

  final previewEntries = <PreviewDetails>[];

  final AnalysisContext _context;
  FunctionDeclaration? _currentFunction;
  ConstructorDeclaration? _currentConstructor;
  MethodDeclaration? _currentMethod;

  /// Handles previews defined on top-level functions.
  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    assert(_currentFunction == null);
    if (node.name.isPrivate) {
      return;
    }

    final TypeAnnotation? returnType = node.returnType;
    if (returnType == null || returnType.question != null) {
      return;
    }
    _scopedVisitChildren(node, (FunctionDeclaration? node) => _currentFunction = node);
  }

  /// Handles previews defined on constructors.
  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    _scopedVisitChildren(node, (ConstructorDeclaration? node) => _currentConstructor = node);
  }

  /// Handles previews defined on static methods within classes.
  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (!node.isStatic) {
      return;
    }
    _scopedVisitChildren(node, (MethodDeclaration? node) => _currentMethod = node);
  }

  @override
  void visitAnnotation(Annotation node) {
    final previewsToProcess = <DartObject>[];
    if (node.isMultiPreview) {
      previewsToProcess.addAll(node.findMultiPreviewPreviewNodes(context: _context));
    } else if (node.isPreview) {
      previewsToProcess.add(node.elementAnnotation!.computeConstantValue()!);
    } else {
      return;
    }

    for (final preview in previewsToProcess) {
      assert(_currentFunction != null || _currentConstructor != null || _currentMethod != null);
      if (_currentFunction != null) {
        final returnType = _currentFunction!.returnType! as NamedType;
        previewEntries.add(
          PreviewDetails(
            packageName: packageName,
            functionName: _currentFunction!.name.toString(),
            isBuilder: returnType.name2.isWidgetBuilder,
            previewAnnotation: preview,
          ),
        );
      } else if (_currentConstructor != null) {
        final returnType = _currentConstructor!.returnType as SimpleIdentifier;
        final Token? name = _currentConstructor!.name;
        previewEntries.add(
          PreviewDetails(
            packageName: packageName,
            functionName: '$returnType${name == null ? '' : '.$name'}',
            isBuilder: false,
            previewAnnotation: preview,
          ),
        );
      } else if (_currentMethod != null) {
        final returnType = _currentMethod!.returnType! as NamedType;
        final parentClass = _currentMethod!.parent! as ClassDeclaration;
        previewEntries.add(
          PreviewDetails(
            packageName: packageName,
            functionName: '${parentClass.name}.${_currentMethod!.name}',
            isBuilder: returnType.name2.isWidgetBuilder,
            previewAnnotation: preview,
          ),
        );
      }
    }
  }

  void _scopedVisitChildren<T extends AstNode>(T node, void Function(T?) setter) {
    setter(node);
    node.visitChildren(this);
    setter(null);
  }
}

/// Contains all the information related to a library being watched by [PreviewDetector].
final class LibraryPreviewNode {
  LibraryPreviewNode({required LibraryElement2 library, required this.logger})
    : path = library.toPreviewPath() {
    final libraryFilePaths = <String>[
      for (final LibraryFragment fragment in library.fragments) fragment.source.fullName,
    ];
    files.addAll(libraryFilePaths);
  }

  final Logger logger;

  /// The path and URI pointing to the library.
  final PreviewPath path;

  /// The set of files contained in the library.
  final files = <String>[];

  /// The list of previews contained within the file.
  final previews = <PreviewDetails>[];

  /// Files that import this file.
  final dependedOnBy = <LibraryPreviewNode>{};

  /// Files this file imports.
  final dependsOn = <LibraryPreviewNode>{};

  /// `true` if a transitive dependency has compile time errors.
  ///
  /// IMPORTANT NOTE: this flag will not be set if there is a compile time error found in a
  /// transitive dependency outside the previewed project (e.g., in a path or Git dependency, or
  /// a modified package).
  // TODO(bkonyi): determine how to best handle compile time errors in non-analyzed dependencies.
  var dependencyHasErrors = false;

  /// `true` if this library contains compile time errors.
  bool get hasErrors => errors.isNotEmpty;

  /// The set of errors found in this library.
  final errors = <AnalysisError>[];

  /// Determines the set of errors found in this library.
  ///
  /// Results in [errors] being populated with the latest set of errors for the library.
  Future<void> populateErrors({required AnalysisContext context}) async {
    errors.clear();
    for (final String file in files) {
      errors.addAll(
        ((await context.currentSession.getErrors(file)) as ErrorsResult).errors
            .where((AnalysisError error) => error.severity == Severity.error)
            .toList(),
      );
    }
  }

  /// Finds all previews defined in the [lib] and adds them to [previews].
  void findPreviews({required ResolvedLibraryResult lib}) {
    // Iterate over the compilation unit's AST to find previews.
    final visitor = _PreviewVisitor(lib: lib.element2);
    for (final ResolvedUnitResult libUnit in lib.units) {
      libUnit.unit.visitChildren(visitor);
    }
    previews
      ..clear()
      ..addAll(visitor.previewEntries);
  }

  /// Updates the dependency [graph] based on changes to a set of compilation [units].
  ///
  /// This method is responsible for:
  ///   - Inserting new nodes into the graph when new dependencies are introduced
  ///   - Computing the set of upstream and downstream dependencies of [units]
  void updateDependencyGraph({
    required PreviewDependencyGraph graph,
    required List<ResolvedUnitResult> units,
  }) {
    final updatedDependencies = <LibraryPreviewNode>{};

    for (final unit in units) {
      final LibraryFragment fragment = unit.libraryFragment;
      for (final LibraryImport importedLib in fragment.libraryImports2) {
        if (importedLib.importedLibrary2 == null) {
          // This is an import for a file that's not analyzed (likely an import of a package from
          // the pub-cache) and isn't necessary to track as part of the dependency graph.
          continue;
        }
        final LibraryElement2 importedLibrary = importedLib.importedLibrary2!;
        final LibraryPreviewNode result = graph.putIfAbsent(
          importedLibrary.toPreviewPath(),
          () => LibraryPreviewNode(library: importedLibrary, logger: logger),
        );
        updatedDependencies.add(result);
      }
    }

    final Set<LibraryPreviewNode> removedDependencies = dependsOn.difference(updatedDependencies);
    for (final removedDependency in removedDependencies) {
      removedDependency.dependedOnBy.remove(this);
    }

    dependsOn
      ..clear()
      ..addAll(updatedDependencies);

    dependencyHasErrors = false;
    for (final dependency in updatedDependencies) {
      dependency.dependedOnBy.add(this);
      if (dependency.dependencyHasErrors || dependency.errors.isNotEmpty) {
        logger.printWarning('Dependency ${dependency.path.uri} has errors');
        dependencyHasErrors = true;
      }
    }
  }

  @override
  String toString() {
    return '(errorCount: ${errors.length} dependencyHasErrors: $dependencyHasErrors '
        'previews: $previews dependedOnBy: ${dependedOnBy.length})';
  }
}
