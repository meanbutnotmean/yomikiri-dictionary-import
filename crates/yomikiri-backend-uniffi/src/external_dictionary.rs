use std::fs::File;
use std::io::{BufWriter, Read, Seek, Write};
use std::path::Path;

use anyhow::{anyhow, Context, Result};
use serde::de::{self, DeserializeSeed, Deserializer, SeqAccess, Visitor};
use serde_json::Value;
use unicode_normalization::UnicodeNormalization;
use zip::ZipArchive;
use yomikiri_dictionary::dictionary::write_entries;
use yomikiri_dictionary::entry::{
    GroupedSense, Kanji, PartOfSpeech, Rarity, Reading, Sense, WordEntry, WordEntryInner,
};

const MAX_METADATA_BYTES: u64 = 4 * 1024 * 1024;
const MAX_TERM_BANK_BYTES: u64 = 128 * 1024 * 1024;
const MAX_TERM_BANK_TOTAL_BYTES: u64 = 512 * 1024 * 1024;
const MAX_ENTRY_COUNT: usize = 1_000_000;

pub struct ImportedDictionaryInfo {
    pub title: String,
    pub entry_count: u64,
}

pub fn import_yomitan_dictionary(
    archive_path: &Path,
    output_path: &Path,
) -> Result<ImportedDictionaryInfo> {
    let file = File::open(archive_path)
        .with_context(|| format!("Could not open dictionary ZIP: {}", archive_path.display()))?;
    let mut archive = ZipArchive::new(file).context("The selected file is not a valid ZIP archive")?;

    let mut metadata_names = archive
        .file_names()
        .filter(|name| matches!(file_name(name), "index.json" | "dictionary.json"))
        .map(str::to_owned)
        .collect::<Vec<_>>();
    metadata_names.sort_by_key(|name| !name.ends_with("index.json"));

    let title = if let Some(name) = metadata_names.first() {
        let metadata = read_zip_entry(&mut archive, name, MAX_METADATA_BYTES)?;
        serde_json::from_str::<Value>(&metadata)
            .ok()
            .and_then(|metadata| metadata.get("title")?.as_str().map(str::to_owned))
            .filter(|title| !title.trim().is_empty())
            .unwrap_or_else(|| archive_path.file_stem().and_then(|s| s.to_str()).unwrap_or("Imported dictionary").to_owned())
    } else {
        archive_path.file_stem().and_then(|s| s.to_str()).unwrap_or("Imported dictionary").to_owned()
    };

    let mut term_bank_names = archive
        .file_names()
        .filter(|name| {
            let name = file_name(name);
            name.starts_with("term_bank_") && name.ends_with(".json")
        })
        .map(str::to_owned)
        .collect::<Vec<_>>();
    term_bank_names.sort();
    if term_bank_names.is_empty() {
        return Err(anyhow!("The ZIP does not contain any term_bank_*.json files"));
    }

    let mut entries = Vec::new();
    let mut total_bytes = 0_u64;
    let mut imported_entry_count = 0_u64;

    for name in term_bank_names {
        let mut bank = archive.by_name(&name).with_context(|| format!("Could not read {name}"))?;
        let bank_size = bank.size();
        if bank_size > MAX_TERM_BANK_BYTES {
            return Err(anyhow!("{name} is larger than the 128 MiB import limit"));
        }
        total_bytes = total_bytes.saturating_add(bank_size);
        if total_bytes > MAX_TERM_BANK_TOTAL_BYTES {
            return Err(anyhow!("The dictionary's term banks are larger than the 512 MiB import limit"));
        }

        let mut deserializer = serde_json::Deserializer::from_reader(&mut bank);
        imported_entry_count += TermBankSeed { entries: &mut entries }
            .deserialize(&mut deserializer)
            .with_context(|| format!("Invalid term bank: {name}"))?;
        deserializer
            .end()
            .with_context(|| format!("Invalid trailing data in term bank: {name}"))?;
    }

    if entries.is_empty() {
        return Err(anyhow!("No searchable term definitions were found in the ZIP"));
    }

    let parent = output_path
        .parent()
        .ok_or_else(|| anyhow!("The output path has no parent directory"))?;
    std::fs::create_dir_all(parent)?;
    let temp_path = output_path.with_extension("yomikiridict.tmp");
    let temp_file = File::create(&temp_path)?;
    let mut writer = BufWriter::new(temp_file);
    write_entries(entries, &mut writer).context("Could not build the imported dictionary")?;
    writer.flush()?;
    writer.get_ref().sync_all()?;
    drop(writer);
    std::fs::rename(&temp_path, output_path).with_context(|| {
        format!("Could not save imported dictionary to {}", output_path.display())
    })?;

    Ok(ImportedDictionaryInfo {
        title,
        entry_count: imported_entry_count,
    })
}

struct TermBankSeed<'a> {
    entries: &'a mut Vec<WordEntry>,
}

impl<'de> DeserializeSeed<'de> for TermBankSeed<'_> {
    type Value = u64;

    fn deserialize<D>(self, deserializer: D) -> std::result::Result<Self::Value, D::Error>
    where
        D: Deserializer<'de>,
    {
        deserializer.deserialize_seq(TermBankVisitor {
            entries: self.entries,
        })
    }
}

struct TermBankVisitor<'a> {
    entries: &'a mut Vec<WordEntry>,
}

impl<'de> Visitor<'de> for TermBankVisitor<'_> {
    type Value = u64;

    fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
        formatter.write_str("an array of Yomitan term entries")
    }

    fn visit_seq<A>(mut self, mut seq: A) -> std::result::Result<Self::Value, A::Error>
    where
        A: SeqAccess<'de>,
    {
        let mut imported = 0_u64;
        while let Some(row) = seq.next_element::<Vec<Value>>()? {
            if self.entries.len() >= MAX_ENTRY_COUNT {
                return Err(de::Error::custom("The dictionary exceeds the 1 million term limit"));
            }
            let id = u32::try_from(self.entries.len() + 1)
                .map_err(|_| de::Error::custom("Too many dictionary entries"))?;
            if let Some(entry) = word_entry_from_row(&row, id) {
                self.entries.push(entry);
                imported += 1;
            }
        }
        Ok(imported)
    }
}

fn word_entry_from_row(row: &[Value], id: u32) -> Option<WordEntry> {
    let term = row.first()?.as_str()?.trim();
    if term.is_empty() {
        return None;
    }
    let term = term.nfc().collect::<String>();

    // Yomitan v3 places score before definitions. Older Yomichan rows place
    // definitions before score and may contain six or seven fields.
    let (definitions_index, score_index) = if row.len() >= 8 { (5, 4) } else { (4, 5) };
    let definitions = row.get(definitions_index)?;
    let mut meanings = Vec::new();
    collect_definition_text(definitions, &mut meanings);
    meanings.retain(|meaning| !meaning.is_empty());
    if meanings.is_empty() {
        return None;
    }

    let has_japanese = term.chars().any(is_japanese_character);
    let reading = (if has_japanese {
        row.get(1)
            .and_then(Value::as_str)
            .filter(|reading| !reading.is_empty())
            .unwrap_or(&term)
    } else {
        &term
    })
    .nfc()
    .collect::<String>();
    let kanjis = if has_japanese {
        vec![Kanji {
            kanji: term.clone(),
            rarity: Rarity::Normal,
        }]
    } else {
        vec![]
    };
    let priority = row
        .get(score_index)
        .and_then(Value::as_f64)
        .filter(|score| score.is_finite() && *score > 0.0)
        .map(|score| score.min(u16::MAX as f64) as u16)
        .unwrap_or(0);
    let to_kanji = if has_japanese {
        vec![term.clone()]
    } else {
        vec![]
    };
    let mut readings = vec![Reading {
        reading,
        nokanji: !has_japanese,
        to_kanji,
        rarity: Rarity::Normal,
    }];
    if !has_japanese {
        let lowercase_reading = term.to_lowercase().nfc().collect::<String>();
        if lowercase_reading != term {
            readings.push(Reading {
                reading: lowercase_reading,
                nokanji: true,
                to_kanji: vec![],
                rarity: Rarity::Search,
            });
        }
    }
    let mut pos = row
        .get(2)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .split_whitespace()
        .filter_map(part_of_speech)
        .collect::<Vec<_>>();
    pos.dedup();
    if pos.is_empty() {
        pos.push(PartOfSpeech::Unclassified);
    }

    WordEntry::new(WordEntryInner {
        id,
        kanjis,
        readings,
        grouped_senses: vec![GroupedSense {
            pos,
            senses: vec![Sense {
                meanings,
                to_kanji: vec![],
                to_reading: vec![],
                misc: vec![],
                info: vec![],
                dialects: vec![],
            }],
        }],
        priority,
    })
    .ok()
}

fn collect_definition_text(value: &Value, output: &mut Vec<String>) {
    let definitions = value.as_array().map(Vec::as_slice).unwrap_or_else(|| std::slice::from_ref(value));
    for definition in definitions {
        let text = definition_text(definition);
        if !text.is_empty() {
            output.push(text);
        }
    }
}

fn definition_text(value: &Value) -> String {
    match value {
        Value::String(text) => strip_html(text),
        Value::Array(items) => items
            .iter()
            .map(definition_text)
            .filter(|text| !text.is_empty())
            .collect::<Vec<_>>()
            .join(" "),
        Value::Object(object) => {
            if object.get("tag").and_then(Value::as_str) == Some("br") {
                return " ".to_owned();
            }
            for key in ["content", "glossary", "text"] {
                if let Some(content) = object.get(key) {
                    return definition_text(content);
                }
            }
            String::new()
        }
        _ => String::new(),
    }
}

fn strip_html(text: &str) -> String {
    let mut plain = String::with_capacity(text.len());
    let mut inside_tag = false;
    for ch in text.chars() {
        match ch {
            '<' => {
                inside_tag = true;
                if !plain.chars().last().map(char::is_whitespace).unwrap_or(false) {
                    plain.push(' ');
                }
            }
            '>' => {
                inside_tag = false;
            }
            _ if !inside_tag => plain.push(ch),
            _ => {}
        }
    }
    plain
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn part_of_speech(tag: &str) -> Option<PartOfSpeech> {
    let tag = tag.to_ascii_lowercase();
    match tag.as_str() {
        "n" | "noun" => Some(PartOfSpeech::Noun),
        "pn" | "pronoun" => Some(PartOfSpeech::Pronoun),
        "v" | "verb" | "v1" | "v1-s" | "v5" | "vk" | "vs" | "vt" | "vi" => {
            Some(PartOfSpeech::Verb)
        }
        "vs-i" | "vs-s" | "vs-c" => Some(PartOfSpeech::SuruVerb),
        "adj" | "adjective" | "adj-i" | "adj-ix" | "adj-f" => {
            Some(PartOfSpeech::Adjective)
        }
        "adj-na" | "adj-nari" => Some(PartOfSpeech::NaAdjective),
        "adv" | "adverb" | "adv-to" => Some(PartOfSpeech::Adverb),
        "prt" | "particle" => Some(PartOfSpeech::Particle),
        "int" | "interjection" => Some(PartOfSpeech::Interjection),
        "conj" | "conjunction" => Some(PartOfSpeech::Conjunction),
        "aux" | "aux-v" | "aux-adj" | "cop" => Some(PartOfSpeech::AuxiliaryVerb),
        "pref" | "prefix" => Some(PartOfSpeech::Prefix),
        "suf" | "suffix" => Some(PartOfSpeech::Suffix),
        "exp" | "expression" => Some(PartOfSpeech::Expression),
        "det" | "adnominal" => Some(PartOfSpeech::Adnomial),
        _ => None,
    }
}

fn is_japanese_character(ch: char) -> bool {
    matches!(
        ch as u32,
        0x3040..=0x30ff | 0x3400..=0x9fff | 0xf900..=0xfaff | 0xff66..=0xff9f
    )
}

fn file_name(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

fn read_zip_entry<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
    name: &str,
    size_limit: u64,
) -> Result<String> {
    let mut file = archive.by_name(name)?;
    if file.size() > size_limit {
        return Err(anyhow!("{name} is larger than the import limit"));
    }
    let mut content = String::with_capacity(file.size() as usize);
    file.read_to_string(&mut content)?;
    Ok(content)
}
