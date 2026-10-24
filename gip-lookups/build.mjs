import fs from "node:fs";
import path from "node:path";

const inputDir = path.resolve(
	process.argv[2] || "gip-lookups/input"
);
const outputFile = path.resolve(
	process.argv[3]
		|| "gip-lookups/build/GipLookups.json"
);

const USED_GROUPS = new Set([
	"base_type",
	"bike_feature",
	"construction_state",
	"edge_category",
	"form_of_way",
	"functional_class",
	"owner",
	"regional_code",
	"surface",
	"sustainer"
]);

function decodeBuffer(buffer) {
	try {
		return new TextDecoder(
			"utf-8",
			{
				fatal: true
			}
		).decode(buffer);
	} catch (_) {
		return new TextDecoder(
			"windows-1252"
		).decode(buffer);
	}
}

function parseCsv(text, delimiter) {
	const rows = [];
	let row = [];
	let value = "";
	let quoted = false;

	for (
		let index = 0;
		index < text.length;
		index += 1
	) {
		const char = text[index];

		if (quoted) {
			if (char === '"') {
				if (text[index + 1] === '"') {
					value += '"';
					index += 1;
				} else {
					quoted = false;
				}
			} else {
				value += char;
			}
			continue;
		}

		if (char === '"') {
			quoted = true;
			continue;
		}
		if (char === delimiter) {
			row.push(value);
			value = "";
			continue;
		}
		if (char === "\n") {
			row.push(value);
			rows.push(row);
			row = [];
			value = "";
			continue;
		}
		if (char === "\r") {
			continue;
		}

		value += char;
	}

	if (
		value.length > 0
		|| row.length > 0
	) {
		row.push(value);
		rows.push(row);
	}

	return rows;
}

function detectDelimiter(text) {
	const candidates = [
		",",
		";",
		"\t"
	];
	let best = ",";
	let bestCount = 0;

	for (const delimiter of candidates) {
		const first = parseCsv(
			text,
			delimiter
		)[0] || [];

		if (first.length > bestCount) {
			best = delimiter;
			bestCount = first.length;
		}
	}

	return best;
}

function normalizeCell(value) {
	const normalized = String(
		value ?? ""
	).trim();

	return normalized === ""
		? null
		: normalized;
}

function normalizeGroupName(fileName) {
	return path.basename(
		fileName,
		path.extname(fileName)
	)
		.replace(/^lut_/i, "")
		.replace(/_csv$/i, "")
		.replace(/_\d{12,14}$/, "")
		.toLowerCase();
}

function displayValue(row) {
	for (const key of [
		"long_name",
		"short_name",
		"name",
		"code",
		"id",
		"short_id"
	]) {
		const value = row[key];

		if (
			value !== null
			&& value !== undefined
			&& value !== ""
		) {
			return value;
		}
	}

	return null;
}

function compactRow(row) {
	const display = displayValue(row);
	const keys = [
		row.id ?? null,
		row.short_id ?? null,
		row.code ?? null,
		row.name ?? null
	];

	if (
		!display
		|| !keys.some((value) => value !== null)
	) {
		return null;
	}

	const compact = [
		display,
		...keys
	];

	while (
		compact.length > 1
		&& compact[compact.length - 1] === null
	) {
		compact.pop();
	}

	return compact;
}

function readLookupCsv(filePath) {
	const text = decodeBuffer(
		fs.readFileSync(filePath)
	);
	const delimiter = detectDelimiter(text);
	const rows = parseCsv(
		text,
		delimiter
	);

	if (rows.length < 2) {
		throw new Error(
			`Leere oder ungültige Lookup-Tabelle: ${filePath}`
		);
	}

	const header = rows.shift()
		.map(normalizeCell);
	const output = [];
	const seen = new Set();

	for (const values of rows) {
		if (
			values.length === 1
			&& !String(values[0] || "").trim()
		) {
			continue;
		}

		const row = {};

		for (
			let index = 0;
			index < header.length;
			index += 1
		) {
			const key = header[index];

			if (!key) continue;
			row[key] = normalizeCell(
				values[index]
			);
		}

		const compact = compactRow(row);
		if (!compact) continue;

		const signature = JSON.stringify(compact);
		if (seen.has(signature)) continue;

		seen.add(signature);
		output.push(compact);
	}

	return output;
}

if (!fs.existsSync(inputDir)) {
	throw new Error(
		`GIP lookup input directory fehlt: ${inputDir}`
	);
}

const csvFiles = fs.readdirSync(inputDir)
	.filter((fileName) => (
		/\.csv$/i.test(fileName)
	))
	.sort((a, b) => (
		a.localeCompare(
			b,
			"en",
			{
				numeric: true,
				sensitivity: "base"
			}
		)
	));

if (csvFiles.length < 10) {
	throw new Error(
		`Unplausibel wenige GIP-Lookuptabellen: ${csvFiles.length}`
	);
}

const latestByGroup = new Map();

for (const fileName of csvFiles) {
	const group = normalizeGroupName(fileName);
	if (!USED_GROUPS.has(group)) continue;

	latestByGroup.set(
		group,
		fileName
	);
}

for (const required of [
	"base_type",
	"bike_feature",
	"edge_category"
]) {
	if (!latestByGroup.has(required)) {
		throw new Error(
			`GIP-Lookuptabelle fehlt: ${required}`
		);
	}
}

const catalog = {};

for (
	const [group, fileName]
	of [...latestByGroup.entries()]
		.sort(([a], [b]) => (
			a.localeCompare(
				b,
				"en",
				{
					numeric: true,
					sensitivity: "base"
				}
		))
) {
	const rows = readLookupCsv(
		path.join(
			inputDir,
			fileName
		)
	);

	if (rows.length > 0) {
		catalog[group] = rows;
	}
}

for (const required of [
	"base_type",
	"bike_feature",
	"edge_category"
]) {
	if (!Array.isArray(catalog[required])) {
		throw new Error(
			`GIP-Lookuptabelle ohne nutzbare Zeilen: ${required}`
		);
	}
}

fs.mkdirSync(
	path.dirname(outputFile),
	{
		recursive: true
	}
);
fs.writeFileSync(
	outputFile,
	JSON.stringify(catalog) + "\n",
	"utf8"
);

console.log(
	[
		`GIP Lookups: ${Object.keys(catalog).length} verwendete Tabellen`,
		`Ausgabe: ${outputFile}`
	].join("\n")
);
