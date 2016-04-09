<?php

namespace PhpIntegrator\Application\Command\SemanticLint;

use PhpIntegrator\DocParser;
use PhpIntegrator\IndexDatabase;

use PhpIntegrator\Indexer\OutlineIndexingVisitor;

/**
 * Analyzes the correctness of docblocks.
 */
class DocblockCorrectnessAnalyzer implements AnalyzerInterface
{
    /**
     * @var OutlineIndexingVisitor
     */
    protected $outlineIndexingVisitor;

    /**
     * @var string
     */
    protected $file;

    /**
     * @var IndexDatabase
     */
    protected $indexDatabase;

    /**
     * @var DocParser
     */
    protected $docParser;

    /**
     * Constructor.
     *
     * @param string        $file
     * @param IndexDatabase $indexDatabase
     */
    public function __construct($file, IndexDatabase $indexDatabase)
    {
        $this->file = $file;
        $this->indexDatabase = $indexDatabase;

        $this->outlineIndexingVisitor = new OutlineIndexingVisitor();
    }

    /**
     * @inheritDoc
     */
    public function getVisitors()
    {
        return [
            $this->outlineIndexingVisitor
        ];
    }

    /**
     * @inheritDoc
     */
    public function getOutput()
    {
        $docblockIssues = [
            'missingDocumentation'  => [],
            'parameterMissing'      => [],
            'parameterTypeMismatch' => [],
            'superfluousParameter'  => []
        ];

        $structures = $this->outlineIndexingVisitor->getStructures();

        foreach ($structures as $structure) {
            $docblockIssues = array_merge_recursive(
                $docblockIssues,
                $this->analyzeStructureDocblock($structure)
            );

            foreach ($structure['methods'] as $method) {
                $docblockIssues = array_merge_recursive(
                    $docblockIssues,
                    $this->analyzeMethodDocblock($structure, $method)
                );
            }

            foreach ($structure['properties'] as $property) {
                $docblockIssues = array_merge_recursive(
                    $docblockIssues,
                    $this->analyzePropertyDocblock($structure, $property)
                );
            }

            foreach ($structure['constants'] as $constant) {
                $docblockIssues = array_merge_recursive(
                    $docblockIssues,
                    $this->analyzeClassConstantDocblock($structure, $constant)
                );
            }
        }

        $globalFunctions = $this->outlineIndexingVisitor->getGlobalFunctions();

        foreach ($globalFunctions as $function) {
            $docblockIssues = array_merge_recursive(
                $docblockIssues,
                $this->analyzeFunctionDocblock($function)
            );
        }

        // TODO: Write tests.
        // TODO: This new code somehow broke the remaining tests.
        // TODO: Before we enable this for everyone, add support to the linter for disabling certain validation. I can
        // imagine some users will find this behavior too aggressive (or simply have codebases that aren't documented
        // properly yet and don't want to get spammed by warnings).

        return $docblockIssues;
    }

    /**
     * @param array $structure
     *
     * @return array
     */
    protected function analyzeStructureDocblock(array $structure)
    {
        if ($structure['docComment']) {
            return [];
        }

        // TODO: Fetch class information to see if 'hasDocumentation' = true.
        return [];
    }

    /**
     * @param array $structure
     * @param array $method
     *
     * @return array
     */
    protected function analyzeMethodDocblock(array $structure, array $method)
    {
        if ($method['docComment']) {
            return $this->analyzeFunctionDocblock($method);
        }

        // TODO: Fetch class information to see if 'hasDocumentation' = true.
        return [];
    }

    /**
     * @param array $structure
     * @param array $method
     *
     * @return array
     */
    protected function analyzePropertyDocblock(array $structure, array $property)
    {
        if ($property['docComment']) {
            // TODO: Warn if there is no @var tag.
            return [];
        }

        // TODO: Fetch class information to see if 'hasDocumentation' = true.
        return [];
    }

    /**
     * @param array $structure
     * @param array $constant
     *
     * @return array
     */
    protected function analyzeClassConstantDocblock(array $structure, array $constant)
    {
        if ($constant['docComment']) {
            // TODO: Warn if there is no @var tag.
            return [];
        }

        // TODO: Fetch class information to see if 'hasDocumentation' = true.
        return [];
    }

    /**
     * @param array $function
     *
     * @return array
     */
    protected function analyzeFunctionDocblock(array $function)
    {
        $docblockIssues = [
            'missingDocumentation'  => [],
            'parameterMissing'      => [],
            'parameterTypeMismatch' => [],
            'superfluousParameter' => []
        ];

        if (!$function['docComment']) {
            $docblockIssues['missingDocumentation'][] = [
                'name'  => $function['name'],
                'line'  => $function['startLine'],
                'start' => $function['startPos'],
                'end'   => $function['endPos']
            ];

            return $docblockIssues;
        }

        $result = $this->getDocParser()->parse($function['docComment'], [DocParser::PARAM_TYPE], $function['name']);

        $keysFound = [];
        $docblockParameters = $result['params'];

        foreach ($function['parameters'] as $parameter) {
            $dollarName = '$' . $parameter['name'];

            if (isset($docblockParameters[$dollarName])) {
                $keysFound[] = $dollarName;
            }

            if (!isset($docblockParameters[$dollarName])) {
                $docblockIssues['parameterMissing'][] = [
                    'name'      => $function['name'],
                    'parameter' => $dollarName,
                    'line'      => $function['startLine'],
                    'start'     => $function['startPos'],
                    'end'       => $function['endPos']
                ];
            } elseif (
                $parameter['type'] &&
                $parameter['type'] !== $docblockParameters[$dollarName]['type']
            ) {
                $docblockIssues['parameterTypeMismatch'][] = [
                    'name'      => $function['name'],
                    'parameter' => $dollarName,
                    'line'      => $function['startLine'],
                    'start'     => $function['startPos'],
                    'end'       => $function['endPos']
                ];
            }
        }

        $superfluousParameterNames = array_values(array_diff(array_keys($docblockParameters), $keysFound));

        if (!empty($superfluousParameterNames)) {
            $docblockIssues['superfluousParameter'][] = [
                'name'       => $function['name'],
                'parameters' => $superfluousParameterNames,
                'line'       => $function['startLine'],
                'start'      => $function['startPos'],
                'end'        => $function['endPos']
            ];
        }

        return $docblockIssues;
    }

    /**
     * @return DocParser
     */
    protected function getDocParser()
    {
        if (!$this->docParser) {
            $this->docParser = new DocParser();
        }

        return $this->docParser;
    }
}
