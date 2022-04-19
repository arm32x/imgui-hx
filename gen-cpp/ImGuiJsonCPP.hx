
import json2object.JsonParser;
import haxe.macro.Expr;
import haxe.macro.Context;
import ImGuiJsonTypes;

using StringTools;
using Lambda;
using Safety;

class ImGuiJsonCPP
{
    final typedefs : JsonTypedef;
    final enumStruct : JsonEnumStruct;
    final definitions : JsonDefinitions;
    
    var abstractPtrs = true;

    public function new(_typedefs : String, _enumStruct : String, _definitions : String)
    {
        typedefs     = new JsonParser<Map<String, String>>().fromJson(_typedefs);
        enumStruct   = new JsonParser<JsonEnumStruct>().fromJson(_enumStruct);
        definitions  = new JsonParser<JsonDefinitions>().fromJson(_definitions);
    }

    /**
     * Generate type definitions for all typedef aliases found in the json.
     * Ignores flags, structs, and iterators and they are generated else where.
     * @return Array<TypeDefinition>
     */
    public function generateTypedefs() : Array<TypeDefinition>
    {
        final gen = [
            { pack: [ 'imguicpp' ], name: 'FILE', pos: null, fields: [], kind: TDAlias(parseNativeString('void')) },
            { pack: [ 'imguicpp' ], name: 'ImGuiWindowPtr', pos: null, fields: [], kind: TDAlias(parseNativeString('void')) }
        ];

        abstractPtrs = false;

        for (name => value in typedefs)
        {
            if (name == 'iterator' ||
                name == 'const_iterator' ||
                name == 'value_type' ||
                name.endsWith('Flags') ||
                value.contains('struct '))
            {
                continue;
            }

            if (enumStruct.enums.exists('${ name }_') || enumStruct.enums.exists(name))
            {
                continue;
            }

            if (value.startsWith("ImBitArray"))
            {
                // Create an empty class for each ImBitArray typedef since Haxe
                // doesn't support templates with values.
                final struct    = macro class $name {};
                struct.isExtern = true;
                struct.meta     = [
                    { name: ':keep', pos : null },
                    { name: ':structAccess', pos : null },
                    { name: ':include', pos : null, params: [ macro $i{ '"imgui.h"' } ] },
                    { name: ':native', pos : null, params: [ macro $i{ '"$value"' } ] }
                ];
                gen.push(struct);
                continue;
            }

            gen.push({ pack: [ 'imguicpp' ], name: name, pos: null, fields: [], kind: TDAlias(parseNativeString(value)) });
        }

        abstractPtrs = true;

        return gen;
    }

    /**
     * Generate type definitions for all the enums found in the json.
     * Integer based abstract enums are generated with implicit to and from int conversions.
     * 
     * The json definition enum names are post fixed with `_` so we substring the last character away.
     * Enum members are also prefixed with the enum struct they belong to, so we remove that from each enum members name.
     * @return Array<TypeDefinition>
     */
    public function generateEnums() : Array<TypeDefinition>
    {
        return [
            for (name => values in enumStruct.enums)
            {
                pack   : [ 'imguicpp' ],
                kind   : TDAbstract(macro : Int, [ macro : Int ], [ macro : Int ]),
                name   : if (name.endsWith('_')) name.substr(0, name.length - 1) else name,
                pos    : null,
                meta   : [ { name: ':enum', pos : null } ],
                fields : [ for (value in values) {
                    name : sanitizeIdentifier(value.name.replace(name, '')),
                    kind : FVar(macro : Int, { pos: null, expr: EConst(CInt('${value.calc_value}')) }),
                    pos  : null,
                } ]
            }
        ];
    }

    /**
     * Ensure a given string is a valid Haxe identifier.
     */
    private function sanitizeIdentifier(name : String) : String
    {
        if (name.charCodeAt(0) >= '0'.code && name.charCodeAt(0) <= '9'.code)
        {
            return '_' + name;
        }
        return name;
    }

    /**
     * Generate externs for each struct in the enums and structs json.
     * Also searches the definitions json for functions which belong to each struct.
     * 
     * Destructors are not current generated, stack based constructors only right now.
     * @return Array<TypeDefinition>
     */
    public function generateStructs() : Array<TypeDefinition>
    {
        final structs = [];

        final tmp = macro class ImGuiDockRequest {};
        tmp.isExtern = true;
        tmp.meta     = [
            { name: ':keep', pos : null },
            { name: ':structAccess', pos : null },
            { name: ':include', pos : null, params: [ macro $i{ '"imgui.h"' } ] },
            { name: ':native', pos : null, params: [ macro $i{ '"ImGuiDockRequest"' } ] }
        ];
        structs.push(tmp);

        final tmp = macro class ImGuiDockNodeSettings {};
        tmp.isExtern = true;
        tmp.meta     = [
            { name: ':keep', pos : null },
            { name: ':structAccess', pos : null },
            { name: ':include', pos : null, params: [ macro $i{ '"imgui.h"' } ] },
            { name: ':native', pos : null, params: [ macro $i{ '"ImGuiDockNodeSettings"' } ] }
        ];
        structs.push(tmp);

        for (name => values in enumStruct.structs)
        {
            final struct    = macro class $name {};
            struct.isExtern = true;
            struct.meta     = [
                { name: ':keep', pos : null },
                { name: ':structAccess', pos : null },
                { name: ':include', pos : null, params: [ macro $i{ '"imgui.h"' } ] },
                { name: ':native', pos : null, params: [ macro $i{ '"$name"' } ] }
            ];

            // Generate fields
            for (value in values)
            {
                // Ignore union types for now
                if (value.type.contains('union {'))
                {
                    continue;
                }

                if (value.type.startsWith('STB_'))
                {
                    continue;
                }

                // Need to do proper cleanup on the final name
                // Quick hack works around it for now...
                var finalType;
                var finalName = value.name.replace('[2]', '');

                if (value.template_type != '')
                {
                    // TODO : Very lazy and should be improved.
                    // Exactly one of the templated types is also a pointer, so do a quick check and manually wrap it.
                    // Can't use parseNativeType as we need a user friendly string name, not the actual type
                    if (value.template_type.contains('*') && !value.template_type.contains('*OrIndex'))
                    {
                        final ctInner = TPath({ pack : [ ], name : 'ImVector${value.template_type.replace('*', '')}Pointer' });

                        finalType = macro : cpp.Star<$ctInner>;
                    }
                    else
                    {
                        finalType = TPath({ pack : [ ], name : 'ImVector${value.template_type.replace(' ', '').replace('*', 'Ptr')}' });
                    }
                }
                else
                {
                    // Get the corresponding (and potentially simplified) complex type.
                    final ctType = parseNativeString(value.type);

                    // If its an array type wrap it in a pointer.
                    // cpp.Star doesn't allow array access so we need to use the old cpp.RawPointer.
                    if (value.size > 0)
                    {
                        // Attempt to simplify again now that its wrapped in a raw pointer
                        finalName = value.name.split('[')[0];
                        finalType = simplifyComplexType(macro : cpp.RawPointer<$ctType>);
                    }
                    else
                    {
                        finalType = ctType;
                    }
                }

                struct.fields.push({
                    name : getHaxefriendlyName(finalName),
                    kind : FVar(finalType),
                    pos  : null,
                    meta : [ { name: ':native', pos : null, params: [ macro $i{ '"$finalName"' } ] } ]
                });
            }

            for (field in generateFunctionFieldsArray(
                definitions.map(f -> f.filter(i -> i.stname == name && !i.destructor)), false))
            {
                struct.fields.push(field);
            }

            structs.push(struct);
        }

        return structs;
    }

    /**
     * Generate an ImVector generic and sub classes for all found ImVectors.
     * Same as structs, no descructors and stack based constructors only.
     * @return Array<TypeDefinition>
     */
    public function generateImVectors() : Array<TypeDefinition>
    {
        final generatedVectors = [];
        final imVectorClass    = macro class ImVector<T> {
            @:native('Data') var data : cpp.RawPointer<T>;
        };
        imVectorClass.isExtern = true;
        imVectorClass.meta     = [
            { name: ':keep', pos : null },
            { name: ':structAccess', pos : null },
            { name: ':include', pos : null, params: [ macro $i{ '"imgui.h"' } ] },
            { name: ':native', pos : null, params: [ macro $i{ '"ImVector"' } ] }
        ];
        imVectorClass.fields = imVectorClass.fields.concat(generateFunctionFieldsArray(
            definitions.map(f -> f.filter(i -> !i.constructor && !i.destructor && i.templated && i.stname == 'ImVector')), false));

        generatedVectors.push(imVectorClass);

        // Compile a list of all known vector templates
        // Search the argument and variable types of all structs and functions.
        final templatedTypes = [];
        for (_ => fields in enumStruct.structs)
        {
            for (field in fields)
            {
                if (field.template_type != '')
                {
                    if (!templatedTypes.has(field.template_type))
                    {
                        templatedTypes.push(field.template_type);
                    }
                }
            }
        }
        for (_ => overloads in definitions)
        {
            for (overloadFn in overloads)
            {
                if (overloadFn.constructor || overloadFn.destructor || overloadFn.templated)
                {
                    continue;
                }

                if (overloadFn.ret.startsWith('ImVector_'))
                {
                    final templatedType = overloadFn.ret.replace('ImVector_', '');
                    if (!templatedTypes.has(templatedType))
                    {
                        templatedTypes.push(templatedType);
                    }
                }

                for (arg in overloadFn.argsT)
                {
                    if (arg.type.startsWith('ImVector_'))
                    {
                        final templatedType = arg.type.replace('ImVector_', '');
                        if (!templatedTypes.has(templatedType))
                        {
                            templatedTypes.push(templatedType);
                        }
                    }
                }
            }
        }

        // Generate an extern for each templated type
        for (templatedType in templatedTypes)
        {
            templatedType = templatedType.replace('*OrIndex', 'PtrOrIndex');
            templatedType = templatedType.replace('const_charPtr*', 'const char*');

            final ct = parseNativeString(templatedType);
            var name = cleanNativeType(templatedType).replace(' ', '');

            for (_ in 0...occurance(templatedType, '*'))
            {
                name += 'Pointer';
            }

            final fullname = 'ImVector$name';
            final templated    = macro class $fullname extends ImVector<$ct> {};
            templated.isExtern = true;
            templated.meta     = [
                { name: ':keep', pos : null },
                { name: ':structAccess', pos : null },
                { name: ':include', pos : null, params: [ macro $i{ '"imgui.h"' } ] },
                { name: ':native', pos : null, params: [ macro $i{ '"ImVector<$templatedType>"' } ] }
            ];

            // Add constructors for each imvector child
            // Has a standard constructor and one which copies from another vector of the same type.
            final constructor : Field = {
                name   : 'create',
                pos    : null,
                access : [ AStatic ], kind: FFun(generateFunctionAst(fullname, false, [], false))
            };
            constructor.meta = [
                { name : ':native', pos : null, params : [ macro $i{ '"ImVector<$templatedType>"' } ] },
                {
                    name   : ':overload',
                    pos    : null,
                    params : [
                        {
                            expr : EFunction(FAnonymous, generateFunctionAst(fullname, false, [ {
                                    name      : 'src',
                                    type      : fullname,
                                    signature : ''
                                } ], true)),
                            pos  : null
                        }
                    ]
                }
            ];

            templated.fields.push(constructor);

            generatedVectors.push(templated);
        }

        return generatedVectors;
    }

    /**
     * Generate an empty extern, needed to create context type.
     * @param _name Name of the extern to generate.
     * @return TypeDefinition
     */
    public function generateEmptyExtern(_name : String) : TypeDefinition
    {
        final def    = macro class $_name {};
        def.isExtern = true;
        def.meta     = [
            { name: ':keep', pos : null },
            { name: ':structAccess', pos : null },
            { name: ':include', pos : null, params: [ macro $i{ '"imgui.h"' } ] },
            { name: ':native', pos : null, params: [ macro $i{ '"$_name"' } ] }
        ];

        return def;
    }

    /**
     * Generate the the type definition for the extern class which will contain all the top level static imgui functions.
     * @return TypeDefinition
     */
    public function generateTopLevelFunctions() : TypeDefinition
    {
        final topLevelClass    = macro class ImGui { };
        topLevelClass.fields   = generateFunctionFieldsArray(definitions.map(f -> f.filter(i -> i.stname == '' && (i.location != null && i.location.startsWith('imgui:')))), true);
        topLevelClass.isExtern = true;
        topLevelClass.meta     = [
            { name: ':keep', pos : null },
            { name: ':structAccess', pos : null },
            { name: ':include', pos : null, params: [ macro $i{ '"linc_imgui.h"' } ] },
            { name: ':build', pos : null, params: [ macro imguicpp.linc.Linc.xml('imgui') ] },
            { name: ':build', pos : null, params: [ macro imguicpp.linc.Linc.touch() ] }
        ];

        return topLevelClass;
    }

    public function topLevelFunctionNeedsWrapping(fn : JsonFunction, ?list : Array<JsonFunction>):Bool {

        var needsWrapping = false;
        if (fn.argsT.length > 0 && fn.argsT[fn.argsT.length-1].type == '...') {
            if (!fn.funcname.startsWith('Log') || fn.funcname.charAt(3).toLowerCase() == fn.funcname.charAt(3)) {
                needsWrapping = true;
            }
        }
        else if (fn.funcname == 'End') {
            needsWrapping = true;
        }
        else {
            for (arg in fn.argsT) {
                var parsedType = parseNativeString(arg.type);
                switch parsedType {
                    default:
                    case TPath(p):
                        if (p.pack.length == 1 && p.pack[0] == 'imguicpp') {
                            if (p.name.endsWith('Pointer')) {
                                needsWrapping = true;
                                break;
                            }
                        }
                }
            }
        }

        if (!needsWrapping && list != null) {
            for (item in list) {
                if (item != fn && item.funcname == fn.funcname) {
                    if (topLevelFunctionNeedsWrapping(item)) {
                        needsWrapping = true;
                        break;
                    }
                }
            }
        }

        return needsWrapping;

    }

    public function retrieveTopLevelWrappedMethods() : Array<JsonFunction> {

        var topLevelDefinitions = definitions.map(f -> f.filter(i -> i.stname == '' && (i.location != null && i.location.startsWith('imgui:'))));
        var result = [];

        for (overloads in topLevelDefinitions.filter(a -> a.length > 0))
        {
            // Check if we need to wrap this method
            var needsWrapping = false;
            for (overloadedFn in overloads)
            {
                if (topLevelFunctionNeedsWrapping(overloadedFn, overloads)) {
                    result.push(overloadedFn);
                }
            }
        }

        return result;

    }

    public function retrieveAllConstructors() : Array<JsonFunction> {

        var filteredDefinitions = definitions.map(f -> f.filter(i -> i.stname != '' && (i.location != null && i.location.startsWith('imgui:'))));
        var result = [];

        for (overloads in filteredDefinitions.filter(a -> a.length > 0))
        {
            for (overloadedFn in overloads)
            {
                if (overloadedFn.constructor) {
                    result.push(overloadedFn);
                }
            }
        }

        return result;

    }

    /**
     * Generates a array of field function definitions.
     * Overloads are generated based on actual overloads and arguments with default values.
     * In haxe default values must be constant, so we use overloads for this.
     * @param _overloads Array of all pre-defined overloads for functions.
     * @param _isTopLevel If this function is to be generated as a static function.
     * @return Array field functions in the type definition format.
     */
    function generateFunctionFieldsArray(_overloads : Array<Array<JsonFunction>>, _isTopLevel : Bool) : Array<Field>
    {
        final fields = [];
        final wrappers = [];

        for (overloads in _overloads.filter(a -> a.length > 0))
        {
            var baseFn = null;

            // Check if we need to wrap this method
            var needsWrapping = false;
            if (_isTopLevel) {
                for (overloadedFn in overloads)
                {
                    needsWrapping = topLevelFunctionNeedsWrapping(overloadedFn);
                    if (needsWrapping)
                        break;
                }
            }

            for (overloadedFn in overloads)
            {
                // Needed to match actual bindings, which differ from cimgui
                if (_isTopLevel) {
                    if (overloadedFn.funcname.startsWith('GetItemRect')) {
                        if (overloadedFn.ret == 'void' && overloadedFn.argsT.length == 1) {
                            overloadedFn.ret = overloadedFn.argsT[0].type.replace('*','');
                            overloadedFn.argsT = [];
                        }
                    }
                }

                var hasVaArgs = false;
                if (overloadedFn.argsT.length > 0 && overloadedFn.argsT[overloadedFn.argsT.length-1].type == '...') {
                    hasVaArgs = true;
                }

                if (baseFn == null)
                {
                    baseFn = generateFunction(overloadedFn, _isTopLevel, overloadedFn.constructor, needsWrapping, hasVaArgs);
                    // if (needsWrapping) {
                    //     baseFn.name = '_' + baseFn.name;
                    // }
                    if (hasVaArgs) {
                        baseFn.meta.push({
                            name   : ':overload',
                            pos    : null,
                            params : [ { pos: null, expr: EFunction(FAnonymous, generateFunctionAst(
                                overloadedFn.constructor ? overloadedFn.stname : overloadedFn.retorig.or(overloadedFn.ret),
                                overloadedFn.retref == '&',
                                overloadedFn.argsT.copy(),
                                true)) } ]
                        });
                    }
                }
                else
                {
                    if (hasVaArgs) {
                        baseFn.meta.push({
                            name   : ':overload',
                            pos    : null,
                            params : [ { pos: null, expr: EFunction(FAnonymous, generateFunctionAst(
                                overloadedFn.constructor ? overloadedFn.stname : overloadedFn.retorig.or(overloadedFn.ret),
                                overloadedFn.retref == '&',
                                overloadedFn.argsT.filter(i -> i.type != '...'),
                                true)) } ]
                        });
                    }
                    
                    baseFn.meta.push({
                        name   : ':overload',
                        pos    : null,
                        params : [ { pos: null, expr: EFunction(FAnonymous, generateFunctionAst(
                            overloadedFn.constructor ? overloadedFn.stname : overloadedFn.retorig.or(overloadedFn.ret),
                            overloadedFn.retref == '&',
                            overloadedFn.argsT.copy(),
                            true)) } ]
                    });
                }

                // if (needsWrapping) {
                //     var wrapper = generateFunctionWrapper(overloadedFn, _isTopLevel, overloadedFn.constructor);
                //     wrappers.push(wrapper);
                // }

                // For each overloaded function also look at the default values.
                // Generate additional overloads by filtering the aguments based on a growing list of arguments to remove.
                // We pop from the list as default arguments 
                final defaults = [ for (k in overloadedFn.defaults.keys()) k ];
                final filtered = [];

                while (defaults.length > 0)
                {
                    filtered.push(defaults.pop());

                    baseFn.meta.push({
                        name   : ':overload',
                        pos    : null,
                        params : [ { pos: null, expr: EFunction(FAnonymous, generateFunctionAst(
                            overloadedFn.constructor ? overloadedFn.stname : overloadedFn.retorig.or(overloadedFn.ret),
                            overloadedFn.retref == '&',
                            overloadedFn.argsT.filter(i -> !filtered.has(i.name)),
                            true)) } ]
                    });
                }
            }

            fields.push(baseFn);

            if (wrappers.length > 1) {
                for (wrapper in wrappers) {
                    wrapper.access.push(AExtern);
                    wrapper.access.push(AOverload);
                }
            }
            while (wrappers.length > 0) {
                fields.push(wrappers.shift());
            }
        }

        return fields;
    }

    /**
     * Generates a field function type definiton from a json definition.
     * @param _function Json definition to generate a function from.
     * @param _isTopLevel If the function doesn't belong to a struct.
     * If true the function is generated as static and the native type is prefixed with the `ImGui::` namespace.
     * @param _isConstructor if this function is a constructor.
     * @param _wrapped if this function is wrapped.
     * @param _filterVaArgs if we should remove ... arg.
     * @return Field
     */
    function generateFunction(_function : JsonFunction, _isTopLevel : Bool, _isConstructor : Bool, _wrapped : Bool, _filterVaArgs : Bool = false) : Field
    {
        final nativeType = _isTopLevel ? 'ImGui::${(_wrapped ? 'linc_' : '') + _function.funcname}' : _function.funcname;
        final funcName   = _isConstructor ? 'create' : getHaxefriendlyName(_function.funcname);
        final returnType = _isConstructor ? _function.stname : _function.retorig.or(_function.ret);

        final args = _filterVaArgs ? _function.argsT.filter(i -> i.type != '...') : _function.argsT.copy();

        return {
            name   : funcName,
            pos    : null,
            access : _isTopLevel || _isConstructor ? [ AStatic ] : [],
            kind   : FFun(generateFunctionAst(returnType, _function.retref == '&', args, false)),
            meta   : [
                { name: ':native', pos : null, params: [ macro $i{ '"$nativeType"' } ] }
            ]
        }
    }

    /**
     * Generates a field function wrapper from a json definition.
     * @param _function Json definition to generate a function from.
     * @param _isTopLevel If the function doesn't belong to a struct.
     * If true the function is generated as static and the native type is prefixed with the `ImGui::` namespace.
     * @param _isConstructor if this function is a constructor.
     * @return Field
     */
    function generateFunctionWrapper(_function : JsonFunction, _isTopLevel : Bool, _isConstructor : Bool, ?filtered : Array<String>) : Field
    {
        final funcName   = _isConstructor ? 'create' : getHaxefriendlyName(_function.funcname);
        final returnType = _isConstructor ? _function.stname : _function.retorig.or(_function.ret);

        var funcArgs;
        if (filtered != null) {
            funcArgs =  _function.argsT.filter(i -> !filtered.has(i.name));
        }
        else {
            funcArgs = _function.argsT.copy();
        }

        return {
            name   : funcName,
            pos    : null,
            access : _isTopLevel || _isConstructor ? [ AStatic, AInline ] : [ AInline ],
            kind   : FFun(generateFunctionWrapperAst(_function, returnType, _function.retref == '&', funcArgs)),
            meta   : [
            ]
        }
    }

    /**
     * Generates an AST representation of a function.
     * AST representations do not contain a function name, this type is then wrapped in an anonymous and function expr or type definition.
     * @param _return String of the native return type.
     * @param _reference If the return type is a reference.
     * @param _args Array of arguments for this function.
     * @param _block If this function should be generated with an EBlock expr (needed for correct overload syntax).
     * @return Function
     */
    function generateFunctionAst(_return : String, _reference : Bool, _args : Array<JsonFunctionArg>, _block : Bool) : Function
    {
        // If the first argument is called 'self' then thats part of cimgui
        // we can safely remove it as we aren't using the c bindings code.
        if (_args.length > 0)
        {
            if (_args[0].name == 'self')
            {
                _args.shift();
            }
        }

        return {
            expr : _block ? { expr: EBlock([]), pos : null } : null,
            ret  : buildReturnType(parseNativeString(_return), _reference),
            args : [ for (arg in _args) generateFunctionArg(arg.name, arg.type) ]
        }
    }

    /**
     * Generates an AST representation of a function wrapper.
     * AST representations do not contain a function name, this type is then wrapped in an anonymous and function expr or type definition.
     * @param _function Json definition of the function being wrapped.
     * @param _return String of the native return type.
     * @param _reference If the return type is a reference.
     * @param _args Array of arguments for this function.
     * @return Function
     */
    function generateFunctionWrapperAst(_function : JsonFunction, _return : String, _reference : Bool, _args : Array<JsonFunctionArg>) : Function
    {
        // If the first argument is called 'self' then thats part of cimgui
        // we can safely remove it as we aren't using the c bindings code.
        if (_args.length > 0)
        {
            if (_args[0].name == 'self')
            {
                _args.shift();
            }
        }

        final funcName = getHaxefriendlyName(_function.funcname);
        final retComplexType = parseNativeString(_return);

        var isVoid = false;
        switch retComplexType {
            default:
            case TPath(p):
                if (p.name == 'Void') {
                    isVoid = true;
                }
        }

        final defaults = [ for (k in _function.defaults.keys()) k ];
        final defaultsForCall = [ for (k in _function.defaults.keys()) k ];
        final filtered = [];

        var exprStr = '{';
        if (!isVoid) {
            exprStr += 'var _res = ';
        }
        if (defaultsForCall.length == 0) {
            exprStr += '_' + funcName + '(';
            for (i in 0..._args.length) {
                var arg = _args[i];
                if (i > 0) {
                    exprStr += ', ';
                }
                exprStr += getHaxefriendlyName(arg.name);
            }
            exprStr += ');';
        }
        else {
            var n = 0;
            do {
                var i = 0;
                if (n > 0) {
                    filtered.push(defaultsForCall.pop());
                    exprStr += 'else ';
                }
                if (defaultsForCall.length > 0) {
                    exprStr += 'if (';
                    i = 0;
                    for (argName in defaultsForCall) {
                        if (i > 0) {
                            exprStr += ' && ';
                        }
                        exprStr += getHaxefriendlyName(argName) + ' != null';
                        i++;
                    }
                    exprStr += ') {';
                }
                else {
                    exprStr += '{';
                }
                exprStr += '_' + funcName + '(';
                i = 0;
                for (arg in _args) {
                    if (filtered.indexOf(arg.name) == -1) {
                        if (i > 0) {
                            exprStr += ', ';
                        }
                        exprStr += getHaxefriendlyName(arg.name);
                        i++;
                    }
                }
                exprStr += ');';
                exprStr += '}';
                n++;
            }
            while (defaultsForCall.length > 0);
            
        }
        exprStr += 'imguicpp.Helpers.flushCallbacks();';
        if (!isVoid) {
            exprStr += 'return _res;';
        }
        exprStr += '}';

        var funcExpr = Context.parse(
            exprStr, 
            Context.currentPos()
        );

        return {
            expr : funcExpr,
            ret  : buildReturnType(isVoid ? macro :Void : retComplexType, _reference),
            args : [ for (arg in _args) { generateFunctionArg(arg.name, arg.type, defaults.indexOf(arg.name) != -1, true); } ]
        }
    }

    /**
     * Generate a function argument AST representation.
     * @param _name name of the argument.
     * Will prefix this with and _ to avoid collisions with haxe preserved keyworks and will force the first character to a lower case.
     * @param _type Native type of this argument.
     * @param _opt Whether the argument is optional or not.
     * @param _wrapper Whether the argument is generated for a function wrapper.
     * @return FunctionArg
     */
    function generateFunctionArg(_name : String, _type : String, _opt : Bool = false, _wrapper : Bool = false) : FunctionArg
    {
        var argType = parseNativeString(_type);

        // switch argType {
        //     default:
        //     case TPath(p):
        //         if (p.pack.length == 2 && p.pack[0] == 'imguicpp' && p.pack[1] == 'utils') {
        //             if (p.name == 'VarConstCharStar') {
        //                 argType = macro :String;
        //             }
        //         }
        // }

        return {
            name : '${ getHaxefriendlyName(_name) }',
            type : argType,
            opt: _opt
        }
    }

    /**
     * Parse the provided string containing a native c type into the equivilent haxe type.
     * Currently parses pointer types and functions.
     * @param _in Native c type.
     * @return ComplexType
     */
    function parseNativeString(_in : String) : ComplexType
    {
        if (_in.contains('(*)'))
        {
            return parseFunction(_in);
        }
        else
        {
            return parseType(_in);
        }
    }

    function parseType(_in : String, _nativeVoid = true) : ComplexType
    {
        // count how many pointer levels then strip any of that away
        final const   = _in.contains('const');
        final pointer = occurance(_in, '*');
        final refType = occurance(_in, '&');
        final cleaned = cleanNativeType(_in);
        var ct;

        if (_in.contains('ImVector_const_charPtr*'))
        {
            return macro : ImVectorcharPointer;
        }

        if (_in == 'ImVector_T *')
        {
            return macro : cpp.Star<ImVector<T>>;
        }

        if (cleaned.startsWith('ImVector_'))
        {
            var hxType = cleaned.replace('ImVector_', '');
            for (_ in 0...pointer)
            {
                hxType += 'Pointer';
            }

            return TPath({ pack: [ ], name: 'ImVector$hxType' });
        }

        if (cleaned.contains('['))
        {
            // Array types use cpp.RawPointer instead of cpp.Star to allow array access
            // Also allows us to pattern match against it and generate abstracts to easy array <-> pointer interop.

            final arrayType = _in.split('[')[0];
            final hxType    = parseType(arrayType);

            ct = macro : cpp.RawPointer<$hxType>;
        }
        else
        {
            ct = getHaxeType(cleaned, _nativeVoid);

            // Get the base complex type, then wrap it in as many pointer as is required.
            for (_ in 0...pointer)
            {
                if (const)
                {
                    ct = macro : cpp.RawConstPointer<$ct>;
                }
                else
                {
                    ct = macro : cpp.Star<$ct>;
                }
            }
            for (_ in 0...refType)
            {
                ct = macro : cpp.Reference<$ct>;
            }

            ct = simplifyComplexType(ct);
        }

        return simplifyComplexType(ct);
    }

    function parseFunction(_in : String) : ComplexType
    {
        final returnType    = _in.split('(*)')[0];
        final bracketedArgs = _in.split('(*)')[1];
        final splitArgs     = bracketedArgs.substr(1, bracketedArgs.length - 2).split(',');

        final ctArgs = [];
        for (arg in splitArgs)
        {
            final split = arg.split(' ');

            final name = split.pop();

            if (name.contains('...'))
            {
                ctArgs.push(macro : haxe.extern.Rest<String>);
            }
            else
            {
                final type = split.join(' ');

                abstractPtrs = false;
    
                ctArgs.push(parseNativeString(type));
    
                abstractPtrs = true;
            }
        }

        final ctParams = TFunction(ctArgs, parseType(returnType, false));

        return macro : cpp.Callable<$ctParams>;
    }

    function buildReturnType(_ct : ComplexType, _reference : Bool)
    {
        if (_reference)
        {
            switch _ct
            {
                case TPath(p):
                    // If the return type is a reference and the outer-most complex type is a pointer
                    // Strip that pointer off and make it a reference instead.
                    if (p.name == 'Star')
                    {
                        return TPath({ pack: [ 'cpp' ], name: 'Reference', params: p.params });
                    }
                case _:
            }
        }

        return _ct;
    }

    function getHaxeType(_in : String, _nativeVoid = true) : ComplexType
    {
        return switch _in.trim()
        {
            case 'int', 'signed int'                        : macro : Int;
            case 'unsigned int'                             : macro : UInt;
            case 'short', 'signed short'                    : macro : cpp.Int16;
            case 'unsigned short'                           : macro : cpp.UInt16;
            case 'float'                                    : macro : cpp.Float32;
            case 'double'                                   : macro : Float;
            case 'bool'                                     : macro : Bool;
            case 'char', 'const char', '_charPtr'           : macro : cpp.Char;
            case 'signed char'                              : macro : cpp.Int8;
            case 'unsigned char'                            : macro : cpp.UInt8;
            case 'int64_t', 'long long', 'signed long long' : macro : cpp.Int64;
            case 'uint64_t', 'unsigned long long'           : macro : cpp.UInt64;
            case 'va_list', '...'                           : macro : cpp.VarArg;
            case 'size_t'                                   : macro : cpp.SizeT;
            case 'void'                                     : _nativeVoid ? macro : cpp.Void : macro : Void;
            case 'T'                                        : macro : T;
            case 'ImVector'                                 : macro : ImVector<T>;
            case _other: TPath({ pack: [ ], name : _other });
        }
    }

    function simplifyComplexType(_ct : ComplexType) : ComplexType
    {
        switch _ct
        {
            case TPath(p):
                // If we have no type parameters there is no simplification we can make.
                if (p.params == null || p.params.length == 0)
                {
                    return _ct;
                }

                // Attempt to simplify some base type pointers to a custom abstracts.
                // Makes common pointer types easier to deal with.
                if (p.name == 'Star' || p.name == 'RawPointer')
                {
                    final inner = getInnerParameter(p.params);

                    switch inner.name
                    {
                        case 'UInt8' if (abstractPtrs): return macro : imguicpp.CharPointer;
                        case 'Void' if (abstractPtrs): return macro : imguicpp.VoidPointer;
                        case 'Int' if (abstractPtrs): return macro : imguicpp.IntPointer;
                        case 'Float32' if (abstractPtrs): return macro : imguicpp.FloatPointer;
                        case 'Bool' if (abstractPtrs): return macro : imguicpp.BoolPointer;
                        case 'Star':
                            final inner = getInnerParameter(inner.params);
                            
                            if (inner.name == 'ImDrawList')
                            {
                                return macro : cpp.RawPointer<cpp.Star<ImDrawList>>;
                            }
                        case _: // Not other pointer simplifications at this point
                    }
                }

                // If we have a RawConstPointer<Int8> the re-type it as a ConstCharStar
                // else, re-type it in a cpp.Star for easier use
                if (p.name == 'RawConstPointer')
                {
                    final inner = getInnerParameter(p.params);

                    switch inner.name
                    {
                        case 'Int8', 'UInt8', 'Char': return macro : imguicpp.utils.VarConstCharStar;
                        case _:
                            final ct = TPath(inner);

                            return macro : cpp.Star<$ct>;
                    }
                }
            case _:
        }

        return _ct;
    }

    function getInnerParameter(_params : Array<TypeParam>) : TypePath
    {
        for (param in _params)
        {
            switch param
            {
                case TPType(t):
                    switch t
                    {
                        case TPath(p): return p;
                        case _:
                    }
                case _:
            }
        }

        return null;
    }

    function occurance(_in : String, _search : String) : Int
    {
        var pointer = 0;
        for (i in 0..._in.length)
        {
            if (_in.charAt(i) == _search)
            {
                pointer++;
            }
        }

        return pointer;
    }

    function getHaxefriendlyName(_in : String)
    {
        if (_in == '...')
        {
            return 'vargs';
        }
        else if (_in == 'in')
        {
            return '_in';
        }
        else
        {
            return '${ _in.charAt(0).toLowerCase() }${ _in.substr(1) }';
        }
    }

    static function cleanNativeType(_in : String) : String
    {
        return _in.replace('*', '').replace('const', '').replace('&', '').trim();
    }
}
