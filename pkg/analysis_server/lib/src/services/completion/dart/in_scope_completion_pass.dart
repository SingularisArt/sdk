// Copyright (c) 2023, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/services/completion/dart/completion_state.dart';
import 'package:analysis_server/src/services/completion/dart/keyword_helper.dart';
import 'package:analysis_server/src/services/completion/dart/suggestion_collector.dart';
import 'package:analysis_server/src/utilities/extensions/ast.dart';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/syntactic_entity.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/src/dart/ast/token.dart';

/// A completion pass that will create candidate suggestions based on the
/// elements in scope in the library containing the selection, as well as
/// suggestions that are not related to elements, such as keywords.
//
// The visit methods in this class are allowed to visit the parent of the
// visited node (the covering node), but are not allowed to visit children. This
// rule will prevent the introduction of an infinite loop between the visit
// methods of the parent and child.
class InScopeCompletionPass extends SimpleAstVisitor<void> {
  /// The state used to compute the candidate suggestions.
  final CompletionState state;

  /// The suggestion collector to which suggestions will be added.
  final SuggestionCollector collector;

  /// A helper that can be used to suggest keywords.
  late final KeywordHelper keywordHelper = KeywordHelper(
      collector: collector, featureSet: featureSet, offset: offset);

  /// Initialize a newly created completion visitor that can use the [state] to
  /// add candidate suggestions to the [collector].
  InScopeCompletionPass({required this.state, required this.collector});

  /// Return the feature set that applies to the library for which completions
  /// are being computed.
  FeatureSet get featureSet => state.libraryElement.featureSet;

  /// Return the offset at which completion was requested.
  int get offset => state.selection.offset;

  /// Return the node that should be used as the context in which completion is
  /// occurring.
  ///
  /// This is normally the covering node, but if the covering node begins with
  /// an identifier (or keyword) and the [offset] is covered by the identifier,
  /// then we look for the highest node that also begins with the same token and
  /// use the parent of that node.
  ///
  /// This allows us more context for completing what the user might be trying
  /// to write and also reduces the complexity of the visitor and reduces the
  /// amount of code duplication.
  AstNode get _completionNode {
    var selection = state.selection;
    var coveringNode = selection.coveringNode;
    var beginToken = coveringNode.beginToken;
    if (!beginToken.isKeywordOrIdentifier ||
        !selection.isCoveredByToken(beginToken)) {
      return coveringNode;
    }
    var child = coveringNode;
    var parent = child.parent;
    while (parent != null && parent.beginToken == beginToken) {
      child = parent;
      parent = child.parent;
    }
    // The [child] is now the highest node that starts with the [beginToken].
    if (parent != null) {
      return parent;
    }
    return child;
  }

  /// Compute the candidate suggestions associated with this pass.
  void computeSuggestions() {
    _completionNode.accept(this);
  }

  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    _visitParentIfAtOrBeforeNode(node);
  }

  @override
  void visitAsExpression(AsExpression node) {
    if (node.asOperator.coversOffset(offset) &&
        node.expression is ParenthesizedExpression) {
      // If the user has typed `as` after something that could be either a
      // parenthesized expression or a parameter list, the parser will recover
      // by parsing an `as` expression. This handles the case where the user is
      // actually trying to write a function expression.
      // TODO(brianwilkerson) Decide whether we should do more to ensure that
      //  the expression could be a parameter list.
      keywordHelper.addFunctionBodyModifiers(null);
    } else if (node.type.coversOffset(offset)) {
      collector.completionLocation = 'AsExpression_type';
      keywordHelper.addKeyword(Keyword.DYNAMIC);
    }
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    collector.completionLocation = 'AssignmentExpression_rightHandSide';
    _forExpression(node);
  }

  @override
  void visitAwaitExpression(AwaitExpression node) {
    collector.completionLocation = 'AwaitExpression_expression';
    _forExpression(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    var operator = node.operator.lexeme;
    collector.completionLocation = 'BinaryExpression_${operator}_rightOperand';
    _forExpression(node);
  }

  @override
  void visitBlock(Block node) {
    if (offset <= node.leftBracket.offset) {
      var parent = node.parent;
      if (parent is BlockFunctionBody) {
        parent.parent?.accept(this);
      }
      return;
    }
    collector.completionLocation = 'Block_statement';
    var previousStatement = node.statements.elementBefore(offset);
    if (previousStatement is TryStatement) {
      if (previousStatement.finallyBlock == null) {
        // TODO(brianwilkerson) Consider adding `on ^ {}`, `catch (e) {^}`, and
        //  `finally {^}`.
        keywordHelper.addKeyword(Keyword.ON);
        keywordHelper.addKeyword(Keyword.CATCH);
        keywordHelper.addKeyword(Keyword.FINALLY);
        if (previousStatement.catchClauses.isEmpty) {
          // If the try statement has no catch, on, or finally then only suggest
          // these keywords, because at least one of these clauses is required.
          return;
        }
      }
    } else if (previousStatement is IfStatement &&
        previousStatement.elseKeyword == null) {
      keywordHelper.addKeyword(Keyword.ELSE);
    }
    _forStatement(node);
    if (node.inCatchClause) {
      keywordHelper.addKeyword(Keyword.RETHROW);
    }
  }

  @override
  void visitBooleanLiteral(BooleanLiteral node) {
    _forExpression(node);
  }

  @override
  void visitCascadeExpression(CascadeExpression node) {
    collector.completionLocation = 'CascadeExpression_cascadeSection';
    _forExpression(node);
  }

  @override
  void visitCaseClause(CaseClause node) {
    collector.completionLocation = 'CaseClause_pattern';
    _forPattern();
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    if (offset < node.classKeyword.offset) {
      keywordHelper.addClassModifiers(node);
      return;
    }
    if (offset <= node.classKeyword.end) {
      keywordHelper.addKeyword(Keyword.CLASS);
      return;
    }
    if (offset <= node.name.end) {
      // TODO(brianwilkerson) Suggest a name for the class.
      return;
    }
    if (offset <= node.leftBracket.offset) {
      keywordHelper.addClassDeclarationKeywords(node);
      return;
    }
    if (offset >= node.leftBracket.end && offset <= node.rightBracket.offset) {
      collector.completionLocation = 'ClassDeclaration_member';
      _forClassMember();
      var element = node.members.elementBefore(offset);
      if (element is MethodDeclaration) {
        var body = element.body;
        if (body.isEmpty) {
          keywordHelper.addFunctionBodyModifiers(body);
        }
      }
    }
  }

  @override
  void visitConditionalExpression(ConditionalExpression node) {
    // TODO(brianwilkerson) Consider adding a location for the condition.
    if (offset >= node.question.end && offset <= node.colon.offset) {
      collector.completionLocation = 'ConditionalExpression_thenExpression';
    } else if (offset >= node.colon.end) {
      collector.completionLocation = 'ConditionalExpression_elseExpression';
    }
    _forExpression(node);
  }

  @override
  void visitConstantPattern(ConstantPattern node) {
    var expression = node.expression;
    if (expression is SimpleIdentifier) {
      node.parent?.accept(this);
    }
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    var separator = node.separator;
    if (separator != null) {
      if (offset >= separator.end && offset <= node.body.offset) {
        collector.completionLocation = 'ConstructorDeclaration_initializer';
        keywordHelper.addConstructorInitializerKeywords(node);
      }
    }
  }

  @override
  void visitConstructorReference(ConstructorReference node) {
    _forExpression(node);
  }

  @override
  void visitDeclaredVariablePattern(DeclaredVariablePattern node) {
    var name = node.name;
    if (name is SyntheticStringToken) {
      return;
    }
    if (node.keyword != null) {
      var type = node.type;
      if (!type.isSimpleIdentifier && name.coversOffset(offset)) {
        // Don't suggest a name for the variable.
        return;
      }
      // Otherwise it's possible that the type is actually the name and the name
      // is the going to be the keyword `when`.
    }
    var parent = node.parent;
    if (!(parent is GuardedPattern && parent.hasWhen)) {
      keywordHelper.addKeyword(Keyword.WHEN);
    }
  }

  @override
  void visitDefaultFormalParameter(DefaultFormalParameter node) {
    var defaultValue = node.defaultValue;
    if (defaultValue is Expression && defaultValue.coversOffset(offset)) {
      collector.completionLocation = 'DefaultFormalParameter_defaultValue';
      _forExpression(defaultValue);
    }
  }

  @override
  void visitDoubleLiteral(DoubleLiteral node) {
    _visitParentIfAtOrBeforeNode(node);
  }

  @override
  void visitEmptyStatement(EmptyStatement node) {
    var parent = node.parent;
    if (parent is Block) {
      var statements = parent.statements;
      var index = statements.indexOf(node);
      if (index > 0) {
        var previousStatement = statements[index - 1];
        if (previousStatement is TryStatement &&
            previousStatement.finallyBlock == null) {
          keywordHelper.addTryClauseKeywords(canHaveFinally: true);
          if (previousStatement.catchClauses.isEmpty) {
            // Don't suggest a new statement because the `try` statement is
            // incomplete.
            return;
          }
        }
      }
    }
    if (offset <= node.semicolon.offset) {
      _forStatement(node);
    }
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    if (!featureSet.isEnabled(Feature.enhanced_enums)) {
      return;
    }
    if (offset < node.enumKeyword.offset) {
      // There are no modifiers for enums.
      return;
    }
    if (offset <= node.enumKeyword.end) {
      keywordHelper.addKeyword(Keyword.ENUM);
      return;
    }
    if (offset <= node.name.end) {
      // TODO(brianwilkerson) Suggest a name for the mixin.
      return;
    }
    if (offset <= node.leftBracket.offset) {
      keywordHelper.addEnumDeclarationKeywords(node);
      return;
    }
    var rightBracket = node.rightBracket;
    if (!rightBracket.isSynthetic && offset >= rightBracket.end) {
      return;
    }
    var semicolon = node.semicolon;
    if (semicolon != null && offset >= semicolon.end) {
      collector.completionLocation = 'EnumDeclaration_member';
      _forEnumMember();
    }
  }

  @override
  void visitExpressionFunctionBody(ExpressionFunctionBody node) {
    var expression = node.expression;
    if (offset >= node.functionDefinition.end && offset <= expression.end) {
      collector.completionLocation = 'ExpressionFunctionBody_expression';
      _forExpression(expression);
    }
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    if (offset < node.extensionKeyword.offset) {
      // There are no modifiers for extensions.
      return;
    }
    if (offset <= node.extensionKeyword.end) {
      keywordHelper.addKeyword(Keyword.EXTENSION);
      return;
    }
    var name = node.name;
    if (name != null && offset <= name.end) {
      // TODO(brianwilkerson) We probably need to suggest `on`.
      // TODO(brianwilkerson) We probably need to suggest `type` when extension
      //  types are supported.
      // Don't suggest a name for the extension.
      return;
    }
    if (offset <= node.leftBracket.offset) {
      if (node.onKeyword.isSynthetic) {
        keywordHelper.addExtensionDeclarationKeywords(node);
      } else {
        collector.completionLocation = 'ExtensionDeclaration_extendedType';
      }
      return;
    }
    if (offset >= node.leftBracket.end && offset <= node.rightBracket.offset) {
      collector.completionLocation = 'ExtensionDeclaration_member';
      _forExtensionMember();
    }
  }

  @override
  void visitExtensionOverride(ExtensionOverride node) {
    _forExpression(node);
  }

  @override
  void visitForElement(ForElement node) {
    var literal = node.thisOrAncestorOfType<TypedLiteral>();
    if (literal is ListLiteral) {
      _forCollectionElement(literal, literal.elements);
    } else if (literal is SetOrMapLiteral) {
      _forCollectionElement(literal, literal.elements);
    }
  }

  @override
  void visitFormalParameterList(FormalParameterList node) {
    if (offset >= node.end) {
      var parent = node.parent;
      if (parent is FunctionExpression) {
        visitFunctionExpression(parent);
      }
    }
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    // If the cursor is at the beginning of the declaration, include the
    // compilation unit keywords. See dartbug.com/41039.
    var returnType = node.returnType;
    if ((returnType == null || returnType.beginToken == returnType.endToken) &&
        offset <= node.name.offset) {
      collector.completionLocation = 'FunctionDeclaration_returnType';
      keywordHelper.addKeyword(Keyword.DYNAMIC);
      keywordHelper.addKeyword(Keyword.VOID);
    }
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    if (offset >=
            (node.parameters?.end ?? node.typeParameters?.end ?? node.offset) &&
        offset <= node.body.offset) {
      var body = node.body;
      keywordHelper.addFunctionBodyModifiers(body);
      var grandParent = node.parent;
      if (body is EmptyFunctionBody &&
          grandParent is FunctionDeclaration &&
          grandParent.parent is CompilationUnit) {
        _forCompilationUnitDeclaration();
      }
    }
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    _forExpression(node);
  }

  @override
  void visitFunctionReference(FunctionReference node) {
    _forExpression(node);
  }

  @override
  void visitGenericTypeAlias(GenericTypeAlias node) {
    if (offset >= node.equals.end && offset <= node.semicolon.offset) {
      keywordHelper.addKeyword(Keyword.DYNAMIC);
      keywordHelper.addKeyword(Keyword.VOID);
    }
  }

  @override
  void visitIfElement(IfElement node) {
    var expression = node.expression;
    if (offset > expression.end && offset <= node.rightParenthesis.offset) {
      var caseClause = node.caseClause;
      if (caseClause == null) {
        keywordHelper.addKeyword(Keyword.CASE);
        keywordHelper.addKeyword(Keyword.IS);
      } else if (caseClause.guardedPattern.hasWhen) {
        if (caseClause.guardedPattern.whenClause?.expression == null) {
          keywordHelper.addExpressionKeywords(node);
        }
      } else {
        keywordHelper.addKeyword(Keyword.WHEN);
      }
    } else if (offset >= node.leftParenthesis.end &&
        offset <= node.rightParenthesis.offset) {
      keywordHelper.addExpressionKeywords(node);
    } else if (offset >= node.rightParenthesis.end) {
      // TODO(brianwilkerson) Ensure that we are suggesting `else` after the
      //  then expression.
      var literal = node.thisOrAncestorOfType<TypedLiteral>();
      if (literal is ListLiteral) {
        _forCollectionElement(literal, literal.elements);
      } else if (literal is SetOrMapLiteral) {
        _forCollectionElement(literal, literal.elements);
      }
      // var thenElement = node.thenElement;
      // if (offset >= thenElement.end &&
      //     !thenElement.isSynthetic &&
      //     node.elseKeyword == null) {
      //   keywordHelper.addKeyword(Keyword.ELSE);
      // }
    }
  }

  @override
  void visitIfStatement(IfStatement node) {
    if (node.rightParenthesis.isSynthetic) {
      // analyzer parser
      // Actual: if (x i^)
      // Parsed: if (x) i^
      keywordHelper.addKeyword(Keyword.IS);
      return;
    }
    var expression = node.expression;
    if (offset > expression.end && offset <= node.rightParenthesis.offset) {
      var caseClause = node.caseClause;
      if (caseClause == null) {
        keywordHelper.addKeyword(Keyword.CASE);
        keywordHelper.addKeyword(Keyword.IS);
      } else if (caseClause.guardedPattern.hasWhen) {
        if (caseClause.guardedPattern.whenClause?.expression == null) {
          _forExpression(node);
        }
      } else {
        keywordHelper.addKeyword(Keyword.WHEN);
      }
    } else if (offset >= node.leftParenthesis.end &&
        offset <= node.rightParenthesis.offset) {
      _forExpression(node);
    } else if (offset >= node.rightParenthesis.end) {
      _forStatement(node);
    }
  }

  @override
  void visitImportDirective(ImportDirective node) {
    if (offset <= node.uri.offset) {
      return;
    } else if (offset <= node.uri.end) {
      // TODO(brianwilkerson) Complete the URI.
    } else {
      keywordHelper.addImportDirectiveKeywords(node);
    }
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    _forExpression(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    var keyword = node.keyword;
    if (keyword != null && offset > keyword.end) {
      // no keywords in 'new ^' expression
    } else {
      _forExpression(node);
    }
  }

  @override
  void visitIntegerLiteral(IntegerLiteral node) {
    _visitParentIfAtOrBeforeNode(node);
  }

  @override
  void visitIsExpression(IsExpression node) {
    if (node.isOperator.coversOffset(offset)) {
      keywordHelper.addKeyword(Keyword.IS);
    } else {
      _forExpression(node);
    }
  }

  @override
  void visitListLiteral(ListLiteral node) {
    final offset = this.offset;
    if (offset >= node.leftBracket.end && offset <= node.rightBracket.offset) {
      collector.completionLocation = 'ListLiteral_element';
      _forCollectionElement(node, node.elements);
    }
  }

  @override
  void visitListPattern(ListPattern node) {
    collector.completionLocation = 'ListPattern_element';
    _forPattern();
  }

  @override
  void visitLogicalAndPattern(LogicalAndPattern node) {
    collector.completionLocation = 'LogicalAndPattern_rightOperand';
    _forPattern();
  }

  @override
  void visitLogicalOrPattern(LogicalOrPattern node) {
    collector.completionLocation = 'LogicalOrPattern_rightOperand';
    _forPattern();
  }

  @override
  void visitMapLiteralEntry(MapLiteralEntry node) {
    if (offset == node.offset) {
      node.parent?.accept(this);
    } else if (offset >= node.separator.end) {
      collector.completionLocation = 'MapLiteralEntry_value';
    }
  }

  @override
  void visitMapPattern(MapPattern node) {
    collector.completionLocation = 'MapPatternEntry_key';
    _forConstantExpression(node);
  }

  @override
  void visitMapPatternEntry(MapPatternEntry node) {
    var separator = node.separator;
    if (separator.isSynthetic || offset <= separator.offset) {
      node.parent?.accept(this);
      return;
    }
    collector.completionLocation = 'MapPatternEntry_value';
    _forPattern();
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (offset >= node.firstTokenAfterCommentAndMetadata.previous!.offset &&
        offset <= node.name.end) {
      keywordHelper.addKeyword(Keyword.DYNAMIC);
      keywordHelper.addKeyword(Keyword.VOID);
      // If the cursor is at the beginning of the declaration, include the class
      // body keywords.  See dartbug.com/41039.
      keywordHelper.addClassMemberKeywords();
    }
    var body = node.body;
    var tokenBeforeBody = body.beginToken.previous!;
    if (offset >= tokenBeforeBody.end && offset <= body.offset) {
      if (body.keyword == null) {
        keywordHelper.addFunctionBodyModifiers(body);
      }
      if (body.isEmpty) {
        keywordHelper.addClassMemberKeywords();
      }
    }
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    if (offset < node.mixinKeyword.offset) {
      keywordHelper.addMixinModifiers(node);
      return;
    }
    if (offset <= node.mixinKeyword.end) {
      keywordHelper.addKeyword(Keyword.MIXIN);
      return;
    }
    if (offset <= node.name.end) {
      // TODO(brianwilkerson) Suggest a name for the mixin.
      return;
    }
    if (offset <= node.leftBracket.offset) {
      keywordHelper.addMixinDeclarationKeywords(node);
      return;
    }
    if (offset >= node.leftBracket.end && offset <= node.rightBracket.offset) {
      collector.completionLocation = 'MixinDeclaration_member';
      _forMixinMember();
      var element = node.members.elementBefore(offset);
      if (element is MethodDeclaration) {
        var body = element.body;
        if (body.isEmpty) {
          keywordHelper.addFunctionBodyModifiers(body);
        }
      }
    }
  }

  @override
  void visitNamedExpression(NamedExpression node) {
    if (offset >= node.name.end) {
      _forExpression(node);
    }
  }

  @override
  void visitNullLiteral(NullLiteral node) {
    _forExpression(node);
  }

  @override
  void visitParenthesizedExpression(ParenthesizedExpression node) {
    var expression = node.expression;
    if (expression is Identifier || expression is PropertyAccess) {
      if (offset == node.rightParenthesis.offset) {
        var next = expression.endToken.next;
        if (next?.type == TokenType.IDENTIFIER) {
          // Fasta parses `if (x i^)` as `if (x ^)` where the `i` is in the
          // token stream but not part of the `ParenthesizedExpression`.
          keywordHelper.addKeyword(Keyword.IS);
          return;
        }
      }
    }
    _forExpression(node);
  }

  @override
  void visitParenthesizedPattern(ParenthesizedPattern node) {
    collector.completionLocation = 'ParenthesizedPattern_expression';
    _forPattern();
  }

  @override
  void visitPatternAssignment(PatternAssignment node) {
    _forExpression(node);
  }

  @override
  void visitPatternField(PatternField node) {
    collector.completionLocation = 'PatternField_pattern';
    var name = node.name;
    if (name == null) {
      var parent = node.parent;
      if (parent is ObjectPattern) {
        // TODO(brianwilkerson) Suggest the properties of the object.
        // _addPropertiesOfType(parent.type.type);
      } else if (parent is RecordPattern) {
        _forPattern();
        // TODO(brianwilkerson) If we know the expected record type, add the
        //  names of any named fields.
      }
    } else if (name.name == null) {
      _forVariablePattern();
    } else {
      _forPattern();
    }
  }

  @override
  void visitPatternVariableDeclaration(PatternVariableDeclaration node) {
    _forExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    _forExpression(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (offset <= node.period.offset) {
      _forExpression(node);
    }
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    _forExpression(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    // suggestions before '.' but not after
    if (offset <= node.operator.offset) {
      _forExpression(node);
    }
  }

  @override
  void visitRecordLiteral(RecordLiteral node) {
    collector.completionLocation = 'RecordLiteral_fields';
    _forExpression(node);
  }

  @override
  void visitRestPatternElement(RestPatternElement node) {
    collector.completionLocation = 'RestPatternElement_pattern';
    _forPattern();
  }

  @override
  void visitReturnStatement(ReturnStatement node) {
    collector.completionLocation = 'ReturnStatement_expression';
    _forExpression(node.expression ?? node);
  }

  @override
  void visitSetOrMapLiteral(SetOrMapLiteral node) {
    var offset = this.offset;
    if (offset >= node.leftBracket.end && offset <= node.rightBracket.offset) {
      collector.completionLocation = 'SetOrMapLiteral_element';
      _forCollectionElement(node, node.elements);
    }
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    _visitParentIfAtOrBeforeNode(node);
  }

  @override
  void visitSpreadElement(SpreadElement node) {
    collector.completionLocation = 'SpreadElement_expression';
    _forExpression(node);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    _visitParentIfAtOrBeforeNode(node);
  }

  @override
  void visitSwitchCase(SwitchCase node) {
    _forStatement(node);
  }

  @override
  void visitSwitchExpression(SwitchExpression node) {
    if (offset >= node.leftParenthesis.end &&
        offset <= node.rightParenthesis.offset) {
      _forExpression(node);
    }
  }

  @override
  void visitSwitchPatternCase(SwitchPatternCase node) {
    if (offset <= node.colon.offset) {
      var previous = node.colon.previous!;
      var previousKeyword = previous.keyword;
      if (previousKeyword == null) {
        if (previous.isSynthetic || previous.coversOffset(offset)) {
          keywordHelper.addExpressionKeywords(node);
          keywordHelper.addKeyword(Keyword.FINAL);
          keywordHelper.addKeyword(Keyword.VAR);
        } else {
          keywordHelper.addKeyword(Keyword.AS);
          keywordHelper.addKeyword(Keyword.WHEN);
        }
      } else if (previousKeyword == Keyword.AS) {
        keywordHelper.addKeyword(Keyword.DYNAMIC);
      } else if (previousKeyword != Keyword.WHEN) {
        keywordHelper.addKeyword(Keyword.AS);
        keywordHelper.addKeyword(Keyword.WHEN);
      }
    } else {
      if (node.statements.isEmpty) {
        keywordHelper.addKeyword(Keyword.CASE);
        keywordHelper.addKeywordFromText(Keyword.DEFAULT, ':');
      }
      keywordHelper.addStatementKeywords(node);
    }
  }

  @override
  void visitSwitchStatement(SwitchStatement node) {
    if (offset >= node.leftParenthesis.end &&
        offset <= node.rightParenthesis.offset) {
      _forExpression(node);
    } else if (offset >= node.leftBracket.end &&
        offset <= node.rightBracket.offset) {
      var members = node.members;
      keywordHelper.addKeyword(Keyword.CASE);
      keywordHelper.addKeywordFromText(Keyword.DEFAULT, ':');
      if (members.isNotEmpty) {
        if (!members.any((element) => element is SwitchDefault)) {
          keywordHelper.addKeywordFromText(Keyword.DEFAULT, ':');
        }
        var element = members.elementBefore(offset);
        if (element != null) {
          _forStatement(node);
        }
      }
    }
  }

  @override
  void visitSymbolLiteral(SymbolLiteral node) {
    _forExpression(node);
  }

  @override
  void visitThisExpression(ThisExpression node) {
    _forExpression(node);
  }

  @override
  void visitThrowExpression(ThrowExpression node) {
    collector.completionLocation = 'ThrowExpression_expression';
    _forExpression(node);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    var variableDeclarationList = node.variables;
    var variables = variableDeclarationList.variables;
    if (variables.isEmpty || offset > variables.first.beginToken.end) {
      return;
    }
    if (node.externalKeyword == null) {
      keywordHelper.addKeyword(Keyword.EXTERNAL);
    }
    if (variableDeclarationList.lateKeyword == null &&
        featureSet.isEnabled(Feature.non_nullable)) {
      keywordHelper.addKeyword(Keyword.LATE);
    }
    if (!variables.first.isConst) {
      keywordHelper.addKeyword(Keyword.CONST);
    }
    if (!variables.first.isFinal) {
      keywordHelper.addKeyword(Keyword.FINAL);
    }
  }

  @override
  void visitTryStatement(TryStatement node) {
    if (offset >= node.body.end) {
      var finallyKeyword = node.finallyKeyword;
      if (finallyKeyword == null) {
        var catchClauses = node.catchClauses;
        var lastClause = catchClauses.lastOrNull;
        if (lastClause == null) {
          keywordHelper.addTryClauseKeywords(canHaveFinally: true);
        } else {
          keywordHelper.addTryClauseKeywords(
              canHaveFinally: offset >= lastClause.end);
        }
      } else if (offset < finallyKeyword.offset) {
        keywordHelper.addTryClauseKeywords(canHaveFinally: false);
      }
    }
  }

  @override
  void visitTypeArgumentList(TypeArgumentList node) {
    keywordHelper.addKeyword(Keyword.DYNAMIC);
    keywordHelper.addKeyword(Keyword.VOID);
  }

  @override
  void visitTypeLiteral(TypeLiteral node) {
    _forExpression(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    var equals = node.equals;
    if (equals != null && offset >= equals.end) {
      collector.completionLocation = 'VariableDeclaration_initializer';
      _forExpression(node);
    }
  }

  @override
  void visitVariableDeclarationList(VariableDeclarationList node) {
    var keyword = node.keyword;
    var variables = node.variables;
    if (variables.isNotEmpty && offset <= variables[0].name.end) {
      var type = node.type;
      if (type == null && keyword?.keyword != Keyword.VAR) {
        keywordHelper.addKeyword(Keyword.DYNAMIC);
        keywordHelper.addKeyword(Keyword.VOID);
      } else if (type is RecordTypeAnnotation) {
        // This might be a record pattern that happens to look like a type, in
        // which case the user might be typing `in`.
        keywordHelper.addKeyword(Keyword.IN);
      }
    }
  }

  @override
  void visitWhenClause(WhenClause node) {
    var whenKeyword = node.whenKeyword;
    if (!whenKeyword.isSynthetic && offset > whenKeyword.end) {
      _forExpression(node);
    }
  }

  /// Add the suggestions that are appropriate when the selection is at the
  /// beginning of a class member.
  void _forClassMember() {
    keywordHelper.addClassMemberKeywords();
    // TODO(brianwilkerson) Suggest type names.
  }

  /// Add the suggestions that are appropriate when the selection is at the
  /// beginning of an element in a collection [literal], with the given
  /// [elements].
  void _forCollectionElement(
      TypedLiteral literal, NodeList<CollectionElement> elements) {
    keywordHelper.addCollectionElementKeywords(literal, elements);
    // TODO(brianwilkerson) Suggest the variables available in the current
    //  scope.
    // _addVariablesInScope(literal);
  }

  /// Add the suggestions that are appropriate when the selection is at the
  /// beginning of a top-level declaration.
  void _forCompilationUnitDeclaration() {
    keywordHelper.addCompilationUnitDeclarationKeywords();
  }

  /// Add the suggestions that are appropriate when the selection is at the
  /// beginning of a constant expression. The [node] provides context to
  /// determine which keywords to include.
  void _forConstantExpression(AstNode node) {
    var inConstantContext = node is Expression && node.inConstantContext;
    keywordHelper.addConstantExpressionKeywords(
        inConstantContext: inConstantContext);
    // TODO(brianwilkerson) Suggest the variables available in the current
    //  scope.
    // _addVariablesInScope(node, mustBeConstant: true);
  }

  /// Add the suggestions that are appropriate when the selection is at the
  /// beginning of an enum member.
  void _forEnumMember() {
    keywordHelper.addEnumMemberKeywords();
  }

  /// Add the suggestions that are appropriate when the selection is at the
  /// beginning of an expression. The [node] provides context to determine which
  /// keywords to include.
  void _forExpression(AstNode? node) {
    keywordHelper.addExpressionKeywords(node);
    // TODO(brianwilkerson) Suggest the variables available in the current
    //  scope.
    // _addVariablesInScope(node);
  }

  /// Add the suggestions that are appropriate when the selection is at the
  /// beginning of an extension member.
  void _forExtensionMember() {
    keywordHelper.addExtensionMemberKeywords();
  }

  /// Add the suggestions that are appropriate when the selection is at the
  /// beginning of a mixin member.
  void _forMixinMember() {
    keywordHelper.addMixinMemberKeywords();
  }

  /// Add the suggestions that are appropriate when the selection is at the
  /// beginning of a pattern.
  void _forPattern() {
    keywordHelper.addPatternKeywords();
  }

  /// Add the suggestions that are appropriate when the selection is at the
  /// beginning of a statement. The [node] provides context to determine which
  /// keywords to include.
  void _forStatement(AstNode node) {
    keywordHelper.addStatementKeywords(node);
  }

  /// Add the suggestions that are appropriate when the selection is at the
  /// beginning of a variable pattern.
  void _forVariablePattern() {
    keywordHelper.addVariablePatternKeywords();
    // TODO(brianwilkerson) Suggest the types available in the currentscope.
    // _addTypesInScope();
  }

  /// If the completion offset is at or before the offset of the [node], then
  /// visit the parent of the node.
  void _visitParentIfAtOrBeforeNode(AstNode node) {
    if (offset <= node.offset) {
      node.parent?.accept(this);
    }
  }
}

extension on GuardedPattern {
  /// Return `true` if this pattern has, or might have, a `when` keyword.
  bool get hasWhen {
    if (whenClause != null) {
      return true;
    }
    var pattern = this.pattern;
    if (pattern is DeclaredVariablePattern) {
      if (pattern.name.lexeme == 'when') {
        final type = pattern.type;
        if (type is NamedType && type.typeArguments == null) {
          return true;
        }
      }
    }
    return false;
  }
}

extension on SyntacticEntity? {
  /// Return `true` if the receiver covers the [offset].
  bool coversOffset(int offset) {
    final self = this;
    return self != null && self.offset <= offset && self.end >= offset;
  }
}

extension on TypeAnnotation? {
  bool get isSimpleIdentifier {
    var self = this;
    return self is NamedType &&
        self.question == null &&
        self.typeArguments == null &&
        self.importPrefix == null;
  }
}
