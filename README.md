# FCE custom PII flags

This is a tool for identifying custom PII and setting flags in FCE. 

These custom flags will appear in RecordPoint metadata under the "Details" tab in the "FileConnect Enterprise" section.

## Installation

### Python Dependencies

Install Python and required packages:

```bash
pip install pyyaml requests
```

### System Dependencies

For the shell scripts, ensure you have:

- **curl** - For API calls to FCE
- **jq** - For JSON parsing (install with `sudo apt-get install jq` on Ubuntu/Debian)

### FCE Configuration

**⚠️ REQUIRED:** This tool requires specific Elasticsearch configuration to function properly. You must configure the following settings before using this tool:

#### Required Elasticsearch Settings

Update all elasticsearch containers in `dockerfile-vm-es3-http.yaml`:

```yaml
- "script.painless.regex.enabled=true"
```

Uncomment this line in the diskover container:

```yaml
- TEXT_KEYWORD_SIZE=32000
```

These settings enable:
- **Painless regex support**: Required for proximity detection in all PII detection modes
- **Keyword field mapping**: Required for efficient regex queries on `document_text.keyword` field

**The tool will validate these settings and exit with an error if not properly configured.**

## Usage

### Basic PII Detection

Basic usage is as follows:

```bash
python pii_detector.py [options] <index_name> <config.yml>
```

Where config.yml is a yaml file that defines the flag name, regular expression, and context words to search for.

### Bulk Processing

For processing multiple YAML files against a single index:

```bash
# Normal PII detection only (recommended for large datasets)
./bulk_custom_pii.sh <index_name> <yaml_directory>

# Include reverse PII detection for complete coverage
./bulk_custom_pii.sh --include-reverse <index_name> <yaml_directory>
```

This script will automatically process all `.yml` files in the specified directory.

### Continuous Crawl Integration

For automated continuous crawl with PII detection or NER extraction:

```bash
# Normal PII detection only (recommended for production)
./continuous_crawl_pii.sh [--test|--no-submit] <index_prefix> <yaml_directory>

# Include reverse PII detection for complete coverage
./continuous_crawl_pii.sh [--test|--no-submit] --include-reverse <index_prefix> <yaml_directory>

# NER extraction mode
./continuous_crawl_pii.sh [--test|--no-submit] --ner <index_prefix> <yaml_directory>

# Force resubmission of all documents (removes previous submission dates)
./continuous_crawl_pii.sh --force-resubmit <index_prefix> <yaml_directory>
```

Options:
- `--test`: Test mode - creates index, runs PII detection, then cleans up
- `--no-submit`: Skip submission but keep the index for review
- `--include-reverse`: Include reverse PII detection (marks non-matching documents as false)
- `--ner`: Run NER extraction instead of PII detection (cannot be combined with --include-reverse)
- `--force-resubmit`: Remove last_submission_date fields to force resubmission of all documents

**⚠️ WARNING**: The `--force-resubmit` flag permanently modifies document metadata by artificially updating `last_modified` timestamps to fake file changes. This is required because FCE only recognizes documents with changed modification dates as resubmission candidates. Use with caution as original timestamp information will be lost.

This script will:
1. Configure FCE for document cracking only
2. Prune old continuous crawl indices with the same prefix
3. Start a new continuous crawl
4. Wait for document cracking to complete
5. Run PII detection or NER extraction using all YAML files in the directory
6. Remove last_submission_date fields if `--force-resubmit` is specified
7. Submit the index (unless in test/no-submit mode)

#### Force Resubmission

The `--force-resubmit` flag is used when you need to resubmit documents that have already been submitted to downstream systems. This is typically required when:

**Common Use Cases:**
- **Adding new PII types**: Customer requires detection of additional PII patterns after initial submission
- **Configuration changes**: PII detection rules have been updated and need to be reapplied
- **Data correction**: Previous PII detection results need to be updated due to improved patterns or checksums
- **Compliance updates**: New regulatory requirements necessitate reprocessing of all documents

**How it works:**
1. **Timestamp modification**: Artificially updates `last_modified` timestamps to current time and sets `file_diff.type = 'modified'` for all documents
2. **Background task execution**: Removes `last_submission_date` fields using an asynchronous Elasticsearch update_by_query operation
3. **Progress monitoring**: Tracks both timestamp updates and field removal progress with real-time updates showing documents processed and batches completed  
4. **Completion verification**: Waits for all operations to complete before proceeding with submission
5. **Forced resubmission**: Documents appear "changed" with recent timestamps and no submission dates, triggering resubmission to downstream systems

**Important Considerations:**
- **⚠️ Timestamp Modification**: The script artificially modifies `last_modified` timestamps to fake file changes, as FCE requires changed modification dates to recognize resubmission candidates
- **Processing time**: Both timestamp updates and field removal run as background tasks and may take significant time for large indexes
- **Resource usage**: The update operations process ALL documents in the index (for timestamps) and all documents with `last_submission_date` fields
- **Downstream impact**: All affected documents will be resubmitted to integrated systems (RecordPoint, etc.) with artificially updated modification dates
- **Metadata integrity**: Original file modification timestamps are permanently altered in the index metadata
- **Use sparingly**: Only use when genuinely needed for new PII requirements, as it triggers complete reprocessing and modifies document metadata

**Example Usage:**
```bash
# Add new PII detection to existing submitted index
./continuous_crawl_pii.sh --force-resubmit customer_docs pii_yml

# Test mode with force resubmit (for validation)  
./continuous_crawl_pii.sh --test --force-resubmit customer_docs pii_yml
```

### Example YAML Configurations

The `pii_yml/` directory contains ready-to-use configurations for common PII types:

- **`pii_medicare_with_checksum.yml`** - Australian Medicare numbers with checksum validation
- **`pii_tfn_with_checksum.yml`** - Australian Tax File Numbers with checksum validation  
- **`pii_passport.yml`** - Passport numbers (basic pattern matching)
- **`pii_ssn.yml`** - US Social Security Numbers (basic pattern matching)

The `ner_yml/` directory contains Named Entity Recognition configurations:

- **`ner_employee_id.yml`** - Employee ID extraction (alphanumeric patterns with letter prefixes)
- **`ner_customer_id.yml`** - Customer ID/CIS Key extraction (8 or 11 digits)

You can use these as-is or modify them for your specific needs.

### YAML file guidelines

Let's take as an example a Medicare number.

![Medicare card](images/medicarecard.png)

This is a 10 digit number which is likely to appear in documents in various formats:
- Continuous: "2953827364"
- Spaced: "2953 82736 4"
- Hyphenated: "2953-82736-4"
- Mixed: "2953 827364" or "295382736 4"

We know that we want the field name in RecordPoint to be HasMedicare.

We know from analyzing the documents that the words "medicare", "bulk billing" or "mbs" (Medicare Benefits Schedule) are likely to appear within 50 characters of the pattern.

Given this we would define the YAML file as such:

```yaml
fieldName: HasMedicare
patternRegex: "[0-9]{4}[ -]?[0-9]{5}[ -]?[0-9]{1}"
contextWords:
  - medicare
  - "bulk billing"
  - mbs
```

**fieldName** is how you want the field to appear in RecordPoint.

![HasMedicare in RecordPoint](images/medicare_in_recordpoint.png)

**patternRegex** is a single regular expression that matches the expected pattern. The `[ -]?` parts allow for optional spaces or dashes between number groups. This pattern will match:
- `2953827364` (continuous)
- `2953 82736 4` (spaces)
- `2953-82736-4` (dashes)
- `2953827364` (mixed formats)

**contextWords** requires at least one of these words to appear within 50 characters of the pattern to prevent false positives.

### Creating Pattern Regex

Building regex patterns involves the following steps:

1. **Define the core pattern**: Use standard regex syntax (e.g., `[0-9]{4}` for 4 digits)
2. **Add separators**: Use `[ -]?` between groups to allow spaces, dashes, or no separator
3. **Include additional characters**: For patterns like dates, use `[ -/]?` to include slashes
4. **Test common formats**: Ensure your pattern matches expected variations

**Examples:**
- **Date of Birth**: `[0-9]{1,2}[ -/]?[0-9]{1,2}[ -/]?[0-9]{4}` matches `15/03/1985`, `15-03-1985`, `15 03 1985`
- **Tax File Number**: `[0-9]{3}[ -]?[0-9]{3}[ -]?[0-9]{3}` matches `123 456 789`, `123-456-789`, `123456789`
- **Social Security**: `[0-9]{3}[ -]?[0-9]{2}[ -]?[0-9]{4}` matches `123 45 6789`, `123-45-6789`

### Flags

The following flags are available:

--dry-run: Reveals the elasticsearch query without executing it. Useful for troubleshooting.

--async: Useful for long running updates, as this can be used to do pii analysis in the background and shows progress (exit the process monitor with ctrl-c).

--search: Instead of updating matching documents with the PII flags, returns the documents themselves. Shows both processed and unprocessed documents that match PII patterns. Useful for verification and analysis.

--reverse: Appends "PII.{name}: false" to documents in the index that do NOT meet the yaml file criteria.

### Performance Considerations

#### Reverse PII Detection Warning

**⚠️ IMPORTANT**: The `--include-reverse` flag can significantly increase processing time and resource usage, especially with large datasets containing millions or billions of documents.

**When to use `--include-reverse`:**
- **Small to medium datasets** (< 1 million documents): Safe to use for complete PII classification
- **Development/testing environments**: Useful for comprehensive validation
- **Compliance requirements**: When you need definitive "true/false" classification for every document

**When to avoid `--include-reverse`:**
- **Large production datasets** (> 10 million documents): Can cause extremely long processing times
- **Time-sensitive operations**: When fast processing is more important than complete coverage
- **Resource-constrained environments**: When Elasticsearch cluster resources are limited

**Performance Impact:**
- **Normal mode**: Only processes documents that match PII patterns (typically 1-5% of total documents)
- **Reverse mode**: Must process ALL documents with `document_text` field (can be 100x more documents)
- **Combined overhead**: Running both modes processes the entire dataset twice

**Recommendation**: Start with normal PII detection only. Add `--include-reverse` only when complete dataset classification is specifically required and you have sufficient time and resources.

## Usage disclaimers

As you would probably expect you would first need to crawl and crack the documents in the index before you can run this as otherwise there will be no as otherwise there will be no document_text field to analyze.

There are some less obvious things to keep in mind, though.

### Compatibility with out of the box PII detection

FCE's out of the box pii scanner will append these fields to each document based on what it finds in document_text.

```json
"PII": {
  "HasPhone": false,
  "HasPCI": false,
  "HasPerson": false,
  "HasPII": false,
  "HasEmail": false
}
```

Worth noting is that after it does so it then proceeds to **delete** the document_text field.

Since pii_detector.py needs the document_text field it seems logical therefore that you should run pii_detector.py first, before the pii api has an opportunity to do so.

However the PII API will skip PII analysis on any documents that already has detected PII and this includes PII detected by pii_detector.py!

This means that if you want both out of the box PII and the PII provided by pii_detector.py you would need to do the following:

1. Crawl
2. Crack
3. OOB PII detection
4. Crack again
5. pii_detector.py
6. Use the clean_document_text api once analysis is done (pii_detector.py won't remove this and you may not want it staying around due to its large size)

Cracking twice is suboptimal though so you may want to decide on one or the other. If you want to go the route of custom PII only then:

1. Crawl
2. Crack
3. pii_detector.py for all required pii
4. Use the clean_document_text api once analysis is done (pii_detector.py won't remove this and you may not want it staying around due to its large size)

If you haven't run OOB PII detection before you submit then the error "[WARNING][fce] Type mapping not found for HasMedicare, assuming String type" will appear in the logs but this won't stop it from submitting.

## Checksum Validation

For certain types of PII, simple pattern matching may result in false positives. For example, any 9-digit sequence near tax-related words might be flagged as a Tax File Number, even if it's not a valid TFN according to the government's validation algorithm.

To address this, the tool supports checksum validation which applies the official validation algorithms to detected patterns, significantly reducing false positives.

### Enabling Checksum Validation

**⚠️ WARNING:** Checksums will increase processing time and resource requirements. Only use checksums if you are experiencing false positives and context words are not effective.

To enable checksum validation, add a `checksum` field to your YAML configuration:

```yaml
fieldName: HasTFN
patternRegex: "[0-9]{3}[ -]?[0-9]{3}[ -]?[0-9]{3}"
contextWords:
  - tfn
  - tax
  - ato
checksum: weighted_mod_11
```

### Available Checksum Algorithms

- **weighted_mod_11**: Australian Tax File Number validation
- **repeating_weight_mod_10**: Australian Medicare number validation

### How It Works

When checksum validation is enabled:

1. The system uses keyword regex to find documents with potential PII patterns near context words
2. Painless scripts extract matches within 50-character proximity of context words
3. Each extracted match is cleaned (removing spaces/dashes) and tested against the checksum algorithm
4. Only patterns that pass checksum validation result in `true` PII flags
5. Documents with patterns that fail validation are marked with `false`

For example, with TFN validation enabled, the sequence "123 456 789" near "tax" might match the pattern, but if it fails the weighted mod 11 checksum, the document will show `HasTFN: false`.

### Benefits

- **Reduced false positives**: Only mathematically valid numbers are flagged
- **Compliance accuracy**: Ensures detected PII matches government validation standards
- **Performance**: Documents already analyzed are automatically skipped on subsequent runs
- **Flexibility**: Can be enabled per PII type as needed

### Adding New Checksum Algorithms

Create a copy of the template file.

```bash
cp checksums/template.painless checksums/{NEW_CHECKSUM_ALGORITHM}.painless
```

Paste the content into a [painless lab](https://www.elastic.co/docs/explore-analyze/scripting/painless-lab).

From here you can develop and test the new algorithm.

## Named Entity Recognition (NER)

The tool includes Named Entity Recognition capabilities specifically designed for structured entity extraction from documents. Unlike traditional PII detection which sets boolean flags, NER mode extracts and stores the actual entity values found in documents.

### NER vs Traditional PII Detection

| Feature | Traditional PII | NER Mode |
|---------|----------------|----------|
| **Output** | Boolean flags (true/false) | Actual extracted values |
| **Storage Location** | `PII.{fieldName}` | `named_entities.{fieldName}` |
| **Use Case** | Compliance flagging | Data extraction & analysis |
| **Performance** | Faster processing | Slightly slower due to extraction |

### Using NER Mode

Enable NER mode with the `--ner` flag:

```bash
# Extract employee IDs using NER
python pii_detector.py --ner <index_name> ner_yml/ner_employee_id.yml

# Preview what will be extracted
python pii_detector.py --ner --search <index_name> ner_yml/ner_customer_id.yml

# Dry run to see the query structure
python pii_detector.py --ner --dry-run <index_name> ner_yml/ner_employee_id.yml
```

### NER Configuration Files

NER configurations use the same YAML structure as traditional PII but are stored in the `ner_yml/` directory:

**Employee ID Example (`ner_yml/ner_employee_id.yml`):**
```yaml
fieldName: EmployeeID
patternRegex: "([FLM][0-9]{6}|[EC][0-9]{5})"
contextWords:
  - employee
  - staff
  - worker
  - personnel
  - associate
```

**Customer ID Example (`ner_yml/ner_customer_id.yml`):**
```yaml
fieldName: CustomerID
patternRegex: "([0-9]{8}|[0-9]{11})"
contextWords:
  - customer
  - client
  - "cis key"
  - "customer id"
  - account
```

### Supported Entity Types

The tool comes with pre-configured NER patterns for:

#### Employee IDs
- **Format A**: Letter (F/L/M) + 6 digits (e.g., `F075971`, `L256743`, `M834567`)
- **Format B**: Letter (E/C) + 5 digits (e.g., `E28014`, `C73490`)

#### Customer IDs / CIS Keys
- **8-digit format**: `12345678`
- **11-digit format**: `12345678901`

### NER Output Format

When NER processing completes, extracted entities are stored in the `named_entities` field:

```json
{
  "_source": {
    "filename": "employee_promotion_memo.docx",
    "document_text": "Staff Member: F075971 has been promoted...",
    "named_entities": {
      "EmployeeID": "F075971"
    }
  }
}
```

### Bulk NER Processing

Use the bulk processing script with NER configurations:

```bash
# Process all NER configurations
./bulk_custom_pii.sh <index_name> ner_yml

# With reverse detection (marks non-matching documents as false)
./bulk_custom_pii.sh --include-reverse <index_name> ner_yml
```

### NER with Continuous Crawl

Integrate NER into continuous crawl workflows:

```bash
# Continuous crawl with NER extraction
./continuous_crawl_pii.sh --ner <index_prefix> ner_yml

# Test mode with NER (creates index, runs NER, then cleans up)
./continuous_crawl_pii.sh --test --ner <index_prefix> ner_yml

# No-submit mode with NER (skips submission but keeps index)
./continuous_crawl_pii.sh --no-submit --ner <index_prefix> ner_yml
```

**Important Notes:**
- The `--ner` flag cannot be combined with `--include-reverse`
- NER mode extracts actual entity values rather than setting boolean flags
- Extracted entities are stored in the `named_entities` field
- Use `ner_yml/` directory for NER configurations


### Creating Custom NER Patterns

To create new NER entity types:

1. **Create YAML configuration** in `ner_yml/` directory:
```yaml
fieldName: YourEntityName
patternRegex: "your_regex_pattern"
contextWords:
  - context1
  - context2
```

2. **Test the pattern** with search mode:
```bash
python pii_detector.py --ner --search <index_name> ner_yml/your_config.yml
```

3. **Execute extraction**:
```bash
python pii_detector.py --ner <index_name> ner_yml/your_config.yml
```

### NER Pattern Design Guidelines

**Effective NER patterns should:**

- **Use capturing groups**: Wrap the main pattern in parentheses for extraction
- **Be specific enough**: Avoid overly broad patterns that match unrelated text
- **Include relevant context**: Use context words that commonly appear near the entity
- **Handle variations**: Account for different formatting (spaces, dashes, etc.)

**Example Pattern Breakdown:**
```yaml
# This pattern matches two different employee ID formats
patternRegex: "([FLM][0-9]{6}|[EC][0-9]{5})"
#              ^-Group 1----^ ^-Group 2---^
#              Format A       Format B
```

### NER Performance Considerations

- **Entity Extraction**: Slightly slower than boolean PII detection due to value extraction
- **Storage Impact**: Named entities add to document size in Elasticsearch
- **Query Performance**: Fast retrieval using structured `named_entities` field
- **Memory Usage**: Minimal additional memory overhead

### Use Cases for NER

**Data Analytics:**
- Extract customer IDs for analysis and reporting
- Build customer journey mapping from document metadata
- Identify employee involvement across documents

**Compliance & Audit:**
- Track specific entity references in documents  
- Generate reports on entity data exposure
- Support data lineage and governance initiatives

**Integration:**
- Export entity data to external systems
- Feed data lakes with structured entity information
- Enable advanced search and filtering capabilities

## RecordPoint Integration - Document Submission Control

For customers using RecordPoint SaaS integration who want to ensure **only documents with detected PII are submitted** to RecordPoint, use the document submission control script.

### When to Use Document Submission Control

**Primary Use Case:**
Some customers require that **only documents containing PII** are submitted to RecordPoint for compliance processing, while documents without PII should be excluded from submission to reduce storage costs and processing overhead.

**How it works:**
- Documents with PII detection results that include at least one `true` value remain eligible for RecordPoint submission
- Documents without any PII fields OR documents where all PII fields are `false` are marked with submission exclusion rules
- The exclusion works by setting `rule_outcome: "Do not submit"` and `rules_name: "Has no PII"` fields that FCE recognizes as submission exemption criteria

### Script Usage

```bash
# Basic usage with default settings (500 req/sec, 1000 docs/batch)
./apply_rules_no_pii_documents.sh <index_name>

# Conservative settings for busy production systems
./apply_rules_no_pii_documents.sh <index_name> --rate-limit=50 --scroll-size=200

# Maximum performance for idle systems
./apply_rules_no_pii_documents.sh <index_name> --rate-limit=1000 --scroll-size=2000

# With monitoring timeout for testing
./apply_rules_no_pii_documents.sh <index_name> --rate-limit=100 --watch-timeout=30
```

### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `--rate-limit=N` | 500 | Requests per second to Elasticsearch |
| `--scroll-size=N` | 1000 | Documents processed per batch |
| `--watch-timeout=N` | unlimited | Stop monitoring after N seconds |

### Performance Guidelines

**Rate Limit Recommendations:**
- **Conservative (busy production):** 10-50 req/sec
- **Balanced (normal production):** 100-200 req/sec  
- **Aggressive (idle systems):** 500+ req/sec

**Scroll Size Recommendations:**
- **Small datasets (< 100K docs):** 100-500 docs/batch
- **Medium datasets (100K-1M docs):** 500-1000 docs/batch
- **Large datasets (> 1M docs):** 1000-2000 docs/batch

### Integration Workflow

**Recommended sequence for RecordPoint customers:**

1. **Crawl and crack documents:**
   ```bash
   # Set up FCE index with document processing
   curl --request POST --url 'http://localhost:8001/v1/indexes/customer_docs/crawl?host_dir=production&data_dir=%2Fdata'
   curl --request POST --url 'http://localhost:8001/v1/indexes/customer_docs/crack-docs'
   ```

2. **Run PII detection:**
   ```bash
   # Detect PII using all available patterns
   ./bulk_custom_pii.sh customer_docs pii_yml
   ```

3. **Apply submission control rules:**
   ```bash
   # Mark documents without PII for exclusion from RecordPoint
   ./apply_rules_no_pii_documents.sh customer_docs --rate-limit=100
   ```

4. **Submit to RecordPoint:**
   ```bash
   # Only documents with PII will be submitted
   curl --request POST --url 'http://localhost:8001/v1/indexes/customer_docs/submit'
   ```

### Monitoring and Progress Tracking

The script provides real-time monitoring with detailed progress information:

```
[00:05:30] Progress: 15750/156000 (10%) | Batches: 16 | Rate: 52 docs/sec | ETA: 45m12s
  🕒 Throttled time: 12s (rate limited to 100 req/sec)
  📈 Rate limit: 100.0 req/sec
```

**Progress indicators:**
- **Timer:** Elapsed time in `[HH:MM:SS]` format
- **Progress:** Current/total documents with percentage
- **Rate:** Actual processing rate in documents per second
- **ETA:** Estimated time to completion
- **Throttling:** Time spent waiting due to rate limits
- **Batches:** Number of processing batches completed

### Document Classification Results

After running the script, documents are classified as:

**Documents that WILL be submitted to RecordPoint:**
- Documents with at least one PII field set to `true`
- Documents that already have `rule_outcome` fields from previous processing

**Documents that will NOT be submitted to RecordPoint:**
- Documents with no PII fields detected
- Documents where all PII fields are `false` (pattern matched but failed validation)

### Verification

Check the results after processing:

```bash
# Count documents marked for exclusion
curl -X GET "localhost:9200/INDEX_NAME/_search?size=0" \
  -H 'content-type: application/json' \
  -d '{"query": {"bool": {"must": [{"term": {"rule_outcome": "Do not submit"}}, {"term": {"rules_name": "Has no PII"}}]}}}'

# View sample excluded documents
curl -X GET "localhost:9200/INDEX_NAME/_search?size=5" \
  -H 'content-type: application/json' \
  -d '{"query": {"term": {"rule_outcome": "Do not submit"}}, "_source": ["filename", "rule_outcome", "rules_name", "PII"]}'
```

### Important Considerations

- **Run after PII detection:** Always run this script AFTER completing PII detection to ensure accurate classification
- **One-time operation:** The script automatically skips documents that already have `rule_outcome` fields
- **Performance impact:** Large datasets may require significant processing time; use appropriate rate limits
- **Reversible:** You can remove the exclusion rules by deleting the `rule_outcome` and `rules_name` fields if needed
- **Compliance:** Ensures only PII-containing documents consume RecordPoint storage and processing resources

## Troubleshooting

### Document Text Keyword Mapping Error

If you see an error about `document_text.keyword` field not being found:

1. Ensure `TEXT_KEYWORD_SIZE=32000` is uncommented in diskover container
2. Redeploy FCE to apply the mapping changes
3. The `document_text` field must be mapped with a keyword subfield for regex queries