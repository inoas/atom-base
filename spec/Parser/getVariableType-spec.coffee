Parser = require '../../lib/Parser'

describe "getVariableType", ->
    editor = null
    grammar = null

    proxyMock = {
        getGlobalFunctions: () ->
            return {}

        getDocParams: (className, funcName) ->
            if className == null and funcName == 'foo'
                return {
                    params:
                        '$test1':
                            type: 'EXPECTED\\TYPE_1'

                        '$test2':
                            type: 'EXPECTED\\TYPE_2'
                }

        autocomplete: (className, element) ->
            return {name: 'EXPECTED_TYPE'} if className == 'Foo' and element == 'bar()'
    }

    parser = new Parser(proxyMock)

    beforeEach ->
        waitsForPromise ->
            atom.workspace.open().then (result) ->
                editor = result

        waitsForPromise ->
            atom.packages.activatePackage('language-php')

        runs ->
            grammar = atom.grammars.selectGrammar('.source.php')

        waitsFor ->
            grammar and editor

        runs ->
            editor.setGrammar(grammar)

    it "returns null for undefined variables.", ->
        source =
            """
            <?php
            """

        editor.setText(source)

        row = editor.getLineCount() - 1
        column = editor.getBuffer().lineLengthForRow(row)

        bufferPosition =
            row    : row
            column : column

        expect(parser.getVariableType(editor, bufferPosition, '$test')).toEqual(null)

    it "correctly skips lines with comments.", ->
        source =
            """
            <?php

            $test = new EXPECTED\\TYPE_1();
            // $test = new EXPECTED\\TYPE_2();
            """

        editor.setText(source)

        row = editor.getLineCount() - 1
        column = editor.getBuffer().lineLengthForRow(row)

        bufferPosition =
            row    : row
            column : column

        expect(parser.getVariableType(editor, bufferPosition, '$test')).toEqual('EXPECTED\\TYPE_1')

    it "correctly returns the type of $this.", ->
        source =
            """
            <?php

            class Bar
            {
                public function __construct()
                {
                    //
                }
            }
            """

        editor.setText(source)

        row = editor.getLineCount() - 3
        column = editor.getBuffer().lineLengthForRow(row)

        bufferPosition =
            row    : row
            column : column

        expect(parser.getVariableType(editor, bufferPosition, '$this')).toEqual('Bar')

    it "correctly returns the type of a variable through a call stack.", ->
        source =
            """
            <?php

            $test = Foo::bar();
            """

        editor.setText(source)

        row = editor.getLineCount() - 1
        column = editor.getBuffer().lineLengthForRow(row)

        bufferPosition =
            row    : row
            column : column

        expect(parser.getVariableType(editor, bufferPosition, '$test')).toEqual('EXPECTED_TYPE')

    it "correctly returns the type of a variable through an instantiation.", ->
        source =
            """
            <?php

            $test = new EXPECTED_TYPE();
            """

        editor.setText(source)

        row = editor.getLineCount() - 1
        column = editor.getBuffer().lineLengthForRow(row)

        bufferPosition =
            row    : row
            column : column

        expect(parser.getVariableType(editor, bufferPosition, '$test')).toEqual('EXPECTED_TYPE')

    it "correctly returns the type of a variable through a catch block type hint.", ->
        source =
            """
            <?php

            try {

            } catch (EXPECTED_TYPE $test) {

            }
            """

        editor.setText(source)

        row = editor.getLineCount() - 2
        column = editor.getBuffer().lineLengthForRow(row)

        bufferPosition =
            row    : row
            column : column

        expect(parser.getVariableType(editor, bufferPosition, '$test')).toEqual('EXPECTED_TYPE')

    it "correctly returns the type of a variable through function parameter type hints.", ->
        source =
            """
            <?php

            function foo(EXPECTED\\TYPE_1 $test1, EXPECTED\\TYPE_2 $test2)
            {

            }
            """

        editor.setText(source)

        row = editor.getLineCount() - 2
        column = editor.getBuffer().lineLengthForRow(row)

        bufferPosition =
            row    : row
            column : column

        expect(parser.getVariableType(editor, bufferPosition, '$test1')).toEqual('EXPECTED\\TYPE_1')
        expect(parser.getVariableType(editor, bufferPosition, '$test2')).toEqual('EXPECTED\\TYPE_2')

    it "correctly returns the type of a variable through the function's docblock.", ->
        source =
            """
            <?php

            function foo($test1, $test2)
            {

            }
            """

        editor.setText(source)

        row = editor.getLineCount() - 2
        column = editor.getBuffer().lineLengthForRow(row)

        bufferPosition =
            row    : row
            column : column

        expect(parser.getVariableType(editor, bufferPosition, '$test1')).toEqual('EXPECTED\\TYPE_1')
        expect(parser.getVariableType(editor, bufferPosition, '$test2')).toEqual('EXPECTED\\TYPE_2')

    it "correctly returns the type of a variable through a PHPStorm-style type annotation.", ->
        source =
            """
            <?php

            /** @var EXPECTED\\TYPE_1 $test */

            some_code_here();
            """

        editor.setText(source)

        row = editor.getLineCount() - 1
        column = editor.getBuffer().lineLengthForRow(row)

        bufferPosition =
            row    : row
            column : column

        expect(parser.getVariableType(editor, bufferPosition, '$test')).toEqual('EXPECTED\\TYPE_1')

    it "correctly returns the type of a variable through a reverse type annotation.", ->
        source =
            """
            <?php

            /** @var $test EXPECTED\\TYPE_1 */

            some_code_here();
            """

        editor.setText(source)

        row = editor.getLineCount() - 1
        column = editor.getBuffer().lineLengthForRow(row)

        bufferPosition =
            row    : row
            column : column

        expect(parser.getVariableType(editor, bufferPosition, '$test')).toEqual('EXPECTED\\TYPE_1')

    it "correctly returns the type of a variable through a simple type annotation on the line before.", ->
        source =
            """
            <?php

            /** @var EXPECTED\\TYPE_1 */
            $test = 5;
            """

        editor.setText(source)

        row = editor.getLineCount() - 1
        column = editor.getBuffer().lineLengthForRow(row)

        bufferPosition =
            row    : row
            column : column

        expect(parser.getVariableType(editor, bufferPosition, '$test')).toEqual('EXPECTED\\TYPE_1')