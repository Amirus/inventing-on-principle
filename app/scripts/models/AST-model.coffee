insertHelpers = (node, parent, chunks, depth) ->
  return unless node.range

  node.depth = depth
  node.parent = parent
  node.source = ->
    chunks[node.range[0]...node.range[1]].join('')

  node.update = (s) ->
    chunks[node.range[0]] = s
    chunks[i] = '' for i in [(node.range[0] + 1)...node.range[1]]
    s

traverse = (ast, chunks, prefunc, postfunc) ->
  walk = (node, parent, depth = 0) =>
    postfunc.call(@, node, parent, chunks, depth) if postfunc?
    _.each node, (child, key) =>
      return if key in ['parent', 'range', 'loc']

      if _.isArray(child)
        _.each child, (grandchild) ->
          walk(grandchild, node, depth + 1) if grandchild and typeof grandchild.type is 'string'

      else if child? and typeof child.type is 'string'
        postfunc.call(@, child, node, chunks, depth) if postfunc?
        walk(child, node, depth)

    prefunc.call(@, node, parent, chunks) if prefunc?

  walk(ast)

inventingOnPrinciple.Models.ASTModel = Backbone.Model.extend
  defaults:
    parsingOptions:
      # Range is required
      range: true
      # comment: true,
      loc: true
      raw: true
      tokens: true

  initialize: (attributes, options) ->
    if attributes? and attributes.text?
      @setSource(attributes.text, options)

    vars = new inventingOnPrinciple.Collections.VariableCollection()
    funs = new inventingOnPrinciple.Collections.FunctionCollection()

    @set({
      vars: vars
      funs: funs
    }, {
      silent: true
    })

    vars
    .on 'change:var', =>
      inventingOnPrinciple.updating = true
      last = inventingOnPrinciple.codeEditor.getValue()
      current = @toSource()
      inventingOnPrinciple.codeEditor.setValue(current)
      inventingOnPrinciple.updating = false
      @instrumentFunctions()
    .on 'endChange', =>
      @trigger 'reparse'


  setSource: (text, options) ->
    return unless typeof text is 'string'

    parsedResult = esprima.parse(text, @get('parsingOptions'))

    tokens = parsedResult.tokens
    ast = _.omit(parsedResult, 'tokens')
    chunks = text.split ''

    @set({
      ast: ast
      chunks: chunks
      tokens: tokens
    }, options)

    @posttraverse insertHelpers
    this

  toSource: ->
    @get('ast').source?()

  traverse: (prefunc, postfunc) ->
    ast = @get('ast')
    chunks = @get('chunks')
    if ast? and chunks?
      traverse.call(this, ast, chunks, prefunc, postfunc)

  pretraverse: (f) ->
    @traverse(f)

  posttraverse: (f) ->
    @traverse(null, f)

  extractFunction: (node, functionList) ->
    parent = node.parent

    func = node: node

    if node.type is Syntax.FunctionDeclaration
      _.extend func,
        name: node.id.name
        range: node.range
        loc: node.loc
        blockStart: node.body.range[0]

    else if node.type is Syntax.FunctionExpression
      if parent.type is Syntax.AssignmentExpression
        if parent.left.range?
          _.extend func,
            name: code.slice(parent.left.range[0], parent.left.range[1] + 1)
            range: node.range
            loc: node.loc
            blockStart: node.body.range[0]

      else if parent.type is Syntax.VariableDeclarator
        _.extend func,
          name: parent.id.name
          range: node.range
          loc: node.loc
          blockStart: node.body.range[0]

      else if parent.type is Syntax.CallExpression
        _.extend func,
          name: (if parent.id then parent.id.name else '[Anonymous]')
          range: node.range
          loc: node.loc
          blockStart: node.body.range[0]

      else if typeof parent.length is 'number'
        _.extend func,
          name: (if parent.id then parent.id.name else '[Anonymous]')
          range: node.range
          loc: node.loc
          blockStart: node.body.range[0]

      else if typeof parent.key isnt 'undefined'
        if parent.key.type is 'Identifier'
          if parent.value is node and parent.key.name
            _.extend func,
              name: parent.key.name
              range: node.range
              loc: node.loc
              blockStart: node.body.range[0]

    functionList.push func if func.name

  instrumentFunctions: ->
    functionList = []
    @pretraverse (node) =>
      @extractFunction(node, functionList)

    @set 'functionList', functionList
    source = @get('ast').source()

    for func in functionList
      params =
        name: func.name
        range: func.range
        loc: func.loc
        lineNumber: if func.loc? then func.loc.start.line else null

      signature = window.tracer.genTraceFunc(params)

      pos = func.blockStart + 1
      source = source.slice(0, pos) + '\n' + signature + source.slice(pos)

    window.tracer.active = true
    inventingOnPrinciple.view.clearConsole()

    try
      eval(source)
    catch e
      console.log(e.toString())
      console.log(e)
      console.log(source)

    hist = window.tracer.funcHistogram()
    @trigger 'tracedFunctions', hist, functionList
    window.tracer.active = false

    this

  extractDeclarations: ->
    map = {}

    @pretraverse (node) ->
      type = node.type.slice(0, -11)
      if node.type.slice(-11) is 'Declaration'
        model = new inventingOnPrinciple.Models[type + 'Model'](node)
        if map[type]
          map[type].push model
        else
          map[type] = [model]

    vars = map['Variable']
    @get('vars').reset vars
    funs = map['Function']
    @get('funs').reset funs
    @trigger 'change:decs', vars, funs

    this

  onASTChange: ->
    try
      generated = window.escodegen.generate(@get('ast'))
      @set generatedCode: generated
    catch e
      console.log 'gen Error', e