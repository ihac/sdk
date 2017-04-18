// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library services.src.completion.statement;

import 'dart:async';

import 'package:analysis_server/plugin/protocol/protocol.dart';
import 'package:analysis_server/src/protocol_server.dart' hide Element;
import 'package:analysis_server/src/services/correction/source_buffer.dart';
import 'package:analysis_server/src/services/correction/source_range.dart';
import 'package:analysis_server/src/services/correction/util.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/error/error.dart' as engine;
import 'package:analyzer/src/dart/ast/utilities.dart';
import 'package:analyzer/src/dart/error/hint_codes.dart';
import 'package:analyzer/src/dart/error/syntactic_errors.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/generated/java_core.dart';
import 'package:analyzer/src/generated/source.dart';

/**
 * An enumeration of possible statement completion kinds.
 */
class DartStatementCompletion {
  static const NO_COMPLETION =
      const StatementCompletionKind('No_COMPLETION', 'No completion available');
  static const SIMPLE_ENTER = const StatementCompletionKind(
      'SIMPLE_ENTER', "Insert a newline at the end of the current line");
  static const SIMPLE_SEMICOLON = const StatementCompletionKind(
      'SIMPLE_SEMICOLON', "Add a semicolon and newline");
  static const COMPLETE_DO_STMT = const StatementCompletionKind(
      'COMPLETE_DO_STMT', "Complete do-statement");
  static const COMPLETE_IF_STMT = const StatementCompletionKind(
      'COMPLETE_IF_STMT', "Complete if-statement");
  static const COMPLETE_FOR_STMT = const StatementCompletionKind(
      'COMPLETE_FOR_STMT', "Complete for-statement");
  static const COMPLETE_WHILE_STMT = const StatementCompletionKind(
      'COMPLETE_WHILE_STMT', "Complete while-statement");
}

/**
 * A description of a statement completion.
 *
 * Clients may not extend, implement or mix-in this class.
 */
class StatementCompletion {
  /**
   * A description of the assist being proposed.
   */
  final StatementCompletionKind kind;

  /**
   * The change to be made in order to apply the assist.
   */
  final SourceChange change;

  /**
   * Initialize a newly created completion to have the given [kind] and [change].
   */
  StatementCompletion(this.kind, this.change);
}

/**
 * The context for computing a statement completion.
 */
class StatementCompletionContext {
  final String file;
  final LineInfo lineInfo;
  final int selectionOffset;
  final CompilationUnit unit;
  final CompilationUnitElement unitElement;
  final List<engine.AnalysisError> errors;

  StatementCompletionContext(this.file, this.lineInfo, this.selectionOffset,
      this.unit, this.unitElement, this.errors) {
    if (unitElement.context == null) {
      throw new Error(); // not reached; see getStatementCompletion()
    }
  }
}

/**
 * A description of a class of statement completions. Instances are intended to
 * hold the information that is common across a number of completions and to be
 * shared by those completions.
 *
 * Clients may not extend, implement or mix-in this class.
 */
class StatementCompletionKind {
  /**
   * The name of this kind of statement completion, used for debugging.
   */
  final String name;

  /**
   * A human-readable description of the changes that will be applied by this
   * kind of statement completion.
   */
  final String message;

  /**
   * Initialize a newly created kind of statement completion to have the given
   * [name] and [message].
   */
  const StatementCompletionKind(this.name, this.message);

  @override
  String toString() => name;
}

/**
 * The computer for Dart statement completions.
 */
class StatementCompletionProcessor {
  static final NO_COMPLETION = new StatementCompletion(
      DartStatementCompletion.NO_COMPLETION, new SourceChange("", edits: []));

  final StatementCompletionContext statementContext;
  final AnalysisContext analysisContext;
  final CorrectionUtils utils;
  int fileStamp;
  AstNode node;
  StatementCompletion completion;
  SourceChange change = new SourceChange('statement-completion');
  List errors = <engine.AnalysisError>[];
  final Map<String, LinkedEditGroup> linkedPositionGroups =
      <String, LinkedEditGroup>{};
  Position exitPosition = null;

  StatementCompletionProcessor(this.statementContext)
      : analysisContext = statementContext.unitElement.context,
        utils = new CorrectionUtils(statementContext.unit) {
    fileStamp = analysisContext.getModificationStamp(source);
  }

  String get eol => utils.endOfLine;

  String get file => statementContext.file;

  LineInfo get lineInfo => statementContext.lineInfo;

  int get requestLine => lineInfo.getLocation(selectionOffset).lineNumber;

  int get selectionOffset => statementContext.selectionOffset;

  Source get source => statementContext.unitElement.source;

  CompilationUnit get unit => statementContext.unit;

  CompilationUnitElement get unitElement => statementContext.unitElement;

  Future<StatementCompletion> compute() async {
    // If the source was changed between the constructor and running
    // this asynchronous method, it is not safe to use the unit.
    if (analysisContext.getModificationStamp(source) != fileStamp) {
      return NO_COMPLETION;
    }
    node = new NodeLocator(selectionOffset).searchWithin(unit);
    if (node == null) {
      return NO_COMPLETION;
    }
    // TODO(messick): This needs to work for declarations.
    node = node.getAncestor((n) => n is Statement);
    if (_isEmptyStatement(node)) {
      node = node.parent;
    }
    for (engine.AnalysisError error in statementContext.errors) {
      if (error.offset >= node.offset &&
          error.offset <= node.offset + node.length) {
        if (error.errorCode is! HintCode) {
          errors.add(error);
        }
      }
    }

    // TODO(messick) Consider changing (some of) this to a visitor.
    if (_complete_ifStatement() ||
        _complete_doStatement() ||
        _complete_forStatement() ||
        _complete_forEachStatement() ||
        _complete_switchStatement() ||
        _complete_tryStatement() ||
        _complete_whileStatement() ||
        _complete_simpleSemicolon() ||
        _complete_simpleEnter()) {
      return completion;
    }
    return NO_COMPLETION;
  }

  void _addInsertEdit(int offset, String text) {
    SourceEdit edit = new SourceEdit(offset, 0, text);
    doSourceChange_addElementEdit(change, unitElement, edit);
  }

  void _addReplaceEdit(SourceRange range, String text) {
    SourceEdit edit = new SourceEdit(range.offset, range.length, text);
    doSourceChange_addElementEdit(change, unitElement, edit);
  }

  void _appendEmptyBraces(SourceBuilder sb, [bool needsExitMark = false]) {
    sb.append('{');
    sb.append(eol);
    String indent = utils.getLinePrefix(selectionOffset);
    sb.append(indent);
    sb.append(utils.getIndent(1));
    if (needsExitMark && sb.exitOffset == null) {
      sb.setExitOffset();
    }
    sb.append(eol);
    sb.append(indent);
    sb.append('}');
  }

  int _appendNewlinePlusIndent() {
    // Append a newline plus proper indent and another newline.
    // Return the position before the second newline.
    String indent = utils.getLinePrefix(selectionOffset);
    int loc = utils.getLineNext(selectionOffset);
    _addInsertEdit(loc, indent + eol);
    return loc + indent.length;
  }

  String _baseNodeText(AstNode astNode) {
    String text = utils.getNodeText(astNode);
    if (text.endsWith(eol)) {
      text = text.substring(0, text.length - eol.length);
    }
    return text;
  }

  bool _complete_doStatement() {
    if (errors.isEmpty || node is! DoStatement) {
      return false;
    }
    DoStatement statement = node;
    SourceBuilder sb = _sourceBuilderAfterKeyword(statement.doKeyword);
    bool hasWhileKeyword = statement.whileKeyword.lexeme == "while";
    int exitDelta = 0;
    if (statement.body is EmptyStatement) {
      String text = utils.getNodeText(statement.body);
      int delta = 0;
      if (text.startsWith(';')) {
        delta = 1;
        _addReplaceEdit(rangeStartLength(statement.body.offset, delta), '');
        if (hasWhileKeyword) {
          text = utils.getNodeText(statement);
          if (text.indexOf(new RegExp(r'do\s*;\s*while')) == 0) {
            int end = text.indexOf('while');
            int start = text.indexOf(';') + 1;
            delta += end - start - 1;
            _addReplaceEdit(
                rangeStartLength(start + statement.offset, end - start), ' ');
          }
        }
        sb = new SourceBuilder(file, sb.offset + delta);
        sb.append(' ');
      }
      _appendEmptyBraces(sb,
          !(hasWhileKeyword && _isSyntheticExpression(statement.condition)));
      if (delta != 0) {
        exitDelta = sb.length - delta;
      }
    } else if (_isEmptyBlock(statement.body)) {
      sb = new SourceBuilder(sb.file, statement.body.end);
    }
    SourceBuilder sb2;
    if (hasWhileKeyword) {
      var stmt = new _KeywordConditionBlockStructure(
          statement.whileKeyword,
          statement.leftParenthesis,
          statement.condition,
          statement.rightParenthesis,
          null);
      sb2 = _complete_keywordCondition(stmt);
      if (sb2.length == 0) {
        // true if condition is '()'
        if (exitPosition != null) {
          if (statement.semicolon.isSynthetic) {
            _insertBuilder(sb);
            sb = new SourceBuilder(file, exitPosition.offset + 1);
            sb.append(';');
          }
        }
      } else {
        if (sb.exitOffset == null && sb2?.exitOffset != null) {
          _insertBuilder(sb);
          sb = sb2;
          sb.append(';');
        } else {
          sb.append(sb2.toString());
        }
      }
    } else {
      sb.append(" while (");
      sb.setExitOffset();
      sb.append(");");
    }
    _insertBuilder(sb);
    if (exitDelta != 0) {
      exitPosition =
          new Position(exitPosition.file, exitPosition.offset + exitDelta);
    }
    _setCompletion(DartStatementCompletion.COMPLETE_DO_STMT);
    return true;
  }

  bool _complete_forEachStatement() {
    // TODO(messick) Implement _complete_forEachStatement
    return false;
  }

  bool _complete_forStatement() {
    if (errors.isEmpty || node is! ForStatement) {
      return false;
    }
    ForStatement forNode = node;
    SourceBuilder sb;
    int delta = 0;
    if (forNode.leftParenthesis.isSynthetic) {
      if (!forNode.rightParenthesis.isSynthetic) {
        return false;
      }
      // keywordOnly (unit test name suffix that exercises this branch)
      sb = _sourceBuilderAfterKeyword(forNode.forKeyword);
      sb.append('(');
      sb.setExitOffset();
      sb.append(')');
    } else {
      if (!forNode.rightSeparator.isSynthetic) {
        // Fully-defined init, cond, updaters so nothing more needed here.
        // emptyParts
        sb = new SourceBuilder(file, forNode.rightParenthesis.offset + 1);
      } else if (!forNode.leftSeparator.isSynthetic) {
        if (_isSyntheticExpression(forNode.condition)) {
          exitPosition = _newPosition(forNode.leftSeparator.offset + 1);
          String text = utils
              .getNodeText(forNode)
              .substring(forNode.leftSeparator.offset - forNode.offset);
          if (text.startsWith(new RegExp(r';\s*\)'))) {
            // emptyCondition
            int end = text.indexOf(')');
            sb = new SourceBuilder(file, forNode.leftSeparator.offset);
            // TODO(messick) Consider adding two semicolons here.
            _addReplaceEdit(rangeStartLength(sb.offset, end), '; ');
            delta = end - '; '.length;
          } else {
            // emptyInitializersEmptyCondition
            exitPosition = _newPosition(forNode.rightParenthesis.offset);
            sb = new SourceBuilder(file, forNode.rightParenthesis.offset);
          }
        } else {
          // emptyUpdaters
          exitPosition = _newPosition(forNode.rightSeparator.offset);
          sb = new SourceBuilder(file, forNode.rightSeparator.offset);
          _addReplaceEdit(rangeStartLength(sb.offset, 0), '; ');
          delta = -'; '.length;
        }
      } else if (_isSyntheticExpression(forNode.initialization)) {
        // emptyInitializers
        exitPosition = _newPosition(forNode.rightParenthesis.offset);
        sb = new SourceBuilder(file, forNode.rightParenthesis.offset);
      } else {
        int start = forNode.condition.offset + forNode.condition.length;
        String text =
            utils.getNodeText(forNode).substring(start - forNode.offset);
        if (text.startsWith(new RegExp(r'\s*\)'))) {
          // missingLeftSeparator
          int end = text.indexOf(')');
          sb = new SourceBuilder(file, start);
          _addReplaceEdit(rangeStartLength(start, end), '; ');
          delta = end - '; '.length;
          exitPosition = new Position(file, start);
        } else {
          // Not possible; any comment following init is attached to init.
          exitPosition = _newPosition(forNode.rightParenthesis.offset);
          sb = new SourceBuilder(file, forNode.rightParenthesis.offset);
        }
      }
    }
    if (forNode.body is EmptyStatement) {
      // keywordOnly
      sb.append(' ');
      _appendEmptyBraces(sb, exitPosition == null);
    }
    if (delta != 0 && exitPosition != null) {
      // missingLeftSeparator
      exitPosition = new Position(file, exitPosition.offset - delta);
    }
    _insertBuilder(sb);
    _setCompletion(DartStatementCompletion.COMPLETE_FOR_STMT);
    return true;
  }

  bool _complete_ifOrWhileStatement(
      _KeywordConditionBlockStructure statement, StatementCompletionKind kind) {
    SourceBuilder sb = _complete_keywordCondition(statement);
    if (statement.block is EmptyStatement) {
      sb.append(' ');
      _appendEmptyBraces(sb, exitPosition == null);
    }
    _insertBuilder(sb);
    _setCompletion(kind);
    return true;
  }

  bool _complete_ifStatement() {
    if (errors.isEmpty || node is! IfStatement) {
      return false;
    }
    IfStatement ifNode = node;
    if (ifNode != null) {
      if (ifNode.elseKeyword != null) {
        return false;
      }
      var stmt = new _KeywordConditionBlockStructure(
          ifNode.ifKeyword,
          ifNode.leftParenthesis,
          ifNode.condition,
          ifNode.rightParenthesis,
          ifNode.thenStatement);
      return _complete_ifOrWhileStatement(
          stmt, DartStatementCompletion.COMPLETE_IF_STMT);
    }
    return false;
  }

  SourceBuilder _complete_keywordCondition(
      _KeywordConditionBlockStructure statement) {
    SourceBuilder sb;
    if (statement.leftParenthesis.isSynthetic) {
      if (!statement.rightParenthesis.isSynthetic) {
        // Quite unlikely to see this so don't try to fix it.
        return null;
      }
      sb = _sourceBuilderAfterKeyword(statement.keyword);
      sb.append('(');
      sb.setExitOffset();
      sb.append(')');
    } else {
      if (_isSyntheticExpression(statement.condition)) {
        exitPosition = _newPosition(statement.leftParenthesis.offset + 1);
        sb = new SourceBuilder(file, statement.rightParenthesis.offset + 1);
      } else {
        sb = new SourceBuilder(file, statement.rightParenthesis.offset + 1);
      }
    }
    return sb;
  }

  bool _complete_simpleEnter() {
    int offset;
    if (!errors.isEmpty) {
      offset = selectionOffset;
    } else {
      String indent = utils.getLinePrefix(selectionOffset);
      int loc = utils.getLineNext(selectionOffset);
      _addInsertEdit(loc, indent + eol);
      offset = loc + indent.length + eol.length;
    }
    _setCompletionAt(DartStatementCompletion.SIMPLE_ENTER, offset);
    return true;
  }

  bool _complete_simpleSemicolon() {
    if (errors.length != 1) {
      return false;
    }
    var error = _findError(ParserErrorCode.EXPECTED_TOKEN, partialMatch: "';'");
    if (error != null) {
      int insertOffset = error.offset + error.length;
      _addInsertEdit(insertOffset, ';');
      int offset = _appendNewlinePlusIndent() + 1 /* ';' */;
      _setCompletionAt(DartStatementCompletion.SIMPLE_SEMICOLON, offset);
      return true;
    }
    return false;
  }

  bool _complete_switchStatement() {
    // TODO(messick) Implement _complete_switchStatement
    return false;
  }

  bool _complete_tryStatement() {
    // TODO(messick) Implement _complete_tryStatement
    return false;
  }

  bool _complete_whileStatement() {
    if (errors.isEmpty || node is! WhileStatement) {
      return false;
    }
    WhileStatement whileNode = node;
    if (whileNode != null) {
      var stmt = new _KeywordConditionBlockStructure(
          whileNode.whileKeyword,
          whileNode.leftParenthesis,
          whileNode.condition,
          whileNode.rightParenthesis,
          whileNode.body);
      return _complete_ifOrWhileStatement(
          stmt, DartStatementCompletion.COMPLETE_WHILE_STMT);
    }
    return false;
  }

  engine.AnalysisError _findError(ErrorCode code, {partialMatch: null}) {
    var error =
        errors.firstWhere((err) => err.errorCode == code, orElse: () => null);
    if (error != null) {
      if (partialMatch != null) {
        return error.message.contains(partialMatch) ? error : null;
      }
      return error;
    }
    return null;
  }

  LinkedEditGroup _getLinkedPosition(String groupId) {
    LinkedEditGroup group = linkedPositionGroups[groupId];
    if (group == null) {
      group = new LinkedEditGroup.empty();
      linkedPositionGroups[groupId] = group;
    }
    return group;
  }

  void _insertBuilder(SourceBuilder builder, [int length = 0]) {
    {
      SourceRange range = rangeStartLength(builder.offset, length);
      String text = builder.toString();
      _addReplaceEdit(range, text);
    }
    // add linked positions
    builder.linkedPositionGroups.forEach((String id, LinkedEditGroup group) {
      LinkedEditGroup fixGroup = _getLinkedPosition(id);
      group.positions.forEach((Position position) {
        fixGroup.addPosition(position, group.length);
      });
      group.suggestions.forEach((LinkedEditSuggestion suggestion) {
        fixGroup.addSuggestion(suggestion);
      });
    });
    // add exit position
    {
      int exitOffset = builder.exitOffset;
      if (exitOffset != null) {
        exitPosition = _newPosition(exitOffset);
      }
    }
  }

  bool _isEmptyBlock(AstNode stmt) {
    return stmt is Block && stmt.statements.isEmpty;
  }

  bool _isSyntheticExpression(Expression expr) {
    return expr is SimpleIdentifier && expr.isSynthetic;
  }

  bool _isEmptyStatement(AstNode stmt) {
    return stmt is EmptyStatement || _isEmptyBlock(stmt);
  }

  Position _newPosition(int offset) {
    return new Position(file, offset);
  }

  void _setCompletion(StatementCompletionKind kind, [List args]) {
    assert(exitPosition != null);
    change.selection = exitPosition;
    change.message = formatList(kind.message, args);
    linkedPositionGroups.values
        .forEach((group) => change.addLinkedEditGroup(group));
    completion = new StatementCompletion(kind, change);
  }

  void _setCompletionAt(StatementCompletionKind kind, int offset, [List args]) {
    exitPosition = _newPosition(offset);
    _setCompletion(kind, args);
  }

  SourceBuilder _sourceBuilderAfterKeyword(Token keyword) {
    SourceBuilder sb;
    String text = _baseNodeText(node);
    text = text.substring(keyword.offset - node.offset);
    int len = keyword.length;
    if (text.length == len ||
        !text.substring(len, len + 1).contains(new RegExp(r'\s'))) {
      sb = new SourceBuilder(file, keyword.offset + len);
      sb.append(' ');
    } else {
      sb = new SourceBuilder(file, keyword.offset + len + 1);
    }
    return sb;
  }
}

// Encapsulate common structure of if-statement and while-statement.
class _KeywordConditionBlockStructure {
  final Token keyword;
  final Token leftParenthesis, rightParenthesis;
  final Expression condition;
  final Statement block;

  _KeywordConditionBlockStructure(this.keyword, this.leftParenthesis,
      this.condition, this.rightParenthesis, this.block);

  int get offset => keyword.offset;
}
