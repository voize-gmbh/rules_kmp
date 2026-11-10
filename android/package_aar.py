"""Packages an Android library as the AAR the Android Gradle plugin's bundle<Variant>Aar writes.

Takes the library's own compiled classes and the AAR rules_android builds for its manifest,
resources and assets, and writes what AGP puts in a library AAR: the classes without R classes,
the manifest with the library's minSdkVersion, resources with each values directory merged into one
file, the library's own symbols in R.txt, consumer keep rules and aar-metadata.properties.
"""

import argparse
import io
import re
import struct
import sys
import zipfile
import xml.etree.ElementTree as ET

# AGP's fixed entry times: classes.jar entries and the AAR's entries.
_CLASSES_TIME = (1981, 1, 1, 1, 1, 0)
_AAR_TIME = (1980, 2, 1, 0, 0, 0)

# Value resource elements and the R type they declare.
_VALUE_TYPES = {
    "attr": "attr",
    "bool": "bool",
    "color": "color",
    "dimen": "dimen",
    "drawable": "drawable",
    "fraction": "fraction",
    "id": "id",
    "integer": "integer",
    "integer-array": "array",
    "macro": "macro",
    "array": "array",
    "string-array": "array",
    "plurals": "plurals",
    "string": "string",
    "style": "style",
    "declare-styleable": "styleable",
}


def _zip_info(name, date_time, is_dir=False, store_dirs=False):
    info = zipfile.ZipInfo(name, date_time)
    info.create_system = 3
    info.external_attr = ((0o40755 if is_dir else 0o100644) << 16) | (0x10 if is_dir else 0)
    info.compress_type = zipfile.ZIP_STORED if is_dir and store_dirs else zipfile.ZIP_DEFLATED
    return info


def _path_order(path):
    return path.split("/")


def _parents(path):
    parts = path.split("/")[:-1]
    return ["/".join(parts[: i + 1]) + "/" for i in range(len(parts))]


def _is_excluded_class(name, namespace_path):
    """The classes AGP leaves out of a library's classes.jar: R classes, Manifest and BuildConfig."""
    base = name.rsplit("/", 1)[-1]
    if base == "R.class" or (base.startswith("R$") and base.endswith(".class")):
        return True
    if not name.startswith(namespace_path + "/") or "/" in name[len(namespace_path) + 1:]:
        return False
    return base in ("Manifest.class", "BuildConfig.class") or (base.startswith("Manifest$") and base.endswith(".class"))


def classes_jar(classes, namespace):
    namespace_path = namespace.replace(".", "/")
    files = {}
    with zipfile.ZipFile(classes) as zf:
        for info in zf.infolist():
            name = info.filename
            if info.is_dir() or name == "META-INF/MANIFEST.MF" or _is_excluded_class(name, namespace_path):
                continue
            files[name] = zf.read(info)
    dirs = sorted({d for name in files for d in _parents(name)})
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w") as zf:
        for d in dirs:
            zf.writestr(_zip_info(d, _CLASSES_TIME, is_dir=True, store_dirs=True), b"")
        for name in sorted(files):
            zf.writestr(_zip_info(name, _CLASSES_TIME), files[name])
    return out.getvalue()


def with_min_sdk(manifest, min_sdk):
    uses_sdk = re.search(r"<uses-sdk\b[^>]*>", manifest)
    if uses_sdk:
        element = uses_sdk.group(0)
        if "android:minSdkVersion=" in element:
            element = re.sub(r'android:minSdkVersion="[^"]*"', 'android:minSdkVersion="%s"' % min_sdk, element)
        else:
            element = element.replace("<uses-sdk", '<uses-sdk android:minSdkVersion="%s"' % min_sdk, 1)
        return manifest[: uses_sdk.start()] + element + manifest[uses_sdk.end():]
    tag = re.search(r"<manifest\b[^>]*>", manifest)
    return manifest[: tag.end()] + '\n\n    <uses-sdk android:minSdkVersion="%s" />' % min_sdk + manifest[tag.end():]


def minimal_manifest(namespace, min_sdk):
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    package="%s" >\n\n'
        '    <uses-sdk android:minSdkVersion="%s" />\n\n'
        "</manifest>" % (namespace, min_sdk)
    )


_XML_NS = "http://www.w3.org/XML/1998/namespace"


class _Prefixes:
    """Prefixes of the XML namespaces a merged values file uses: ns1, ns2, ... in order of first use,
    declared on its root as AGP's resource merger does."""

    def __init__(self):
        self.prefixes = {}

    def qname(self, name):
        if not name.startswith("{"):
            return name
        ns, local = name[1:].split("}", 1)
        if ns == _XML_NS:
            return "xml:" + local
        if ns not in self.prefixes:
            self.prefixes[ns] = "ns%d" % (len(self.prefixes) + 1)
        return self.prefixes[ns] + ":" + local

    def declarations(self):
        return "".join(' xmlns:%s="%s"' % (prefix, _escape(ns, True)) for ns, prefix in self.prefixes.items())


def _escape(text, attr=False):
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return text.replace('"', "&quot;") if attr else text


def _start_tag(element, prefixes):
    tag = prefixes.qname(element.tag)
    attrs = "".join(' %s="%s"' % (prefixes.qname(k), _escape(v, True)) for k, v in element.attrib.items())
    return tag, attrs


def _inline(element, prefixes):
    """The element with its text and children as they are, for mixed content such as styled strings."""
    tag, attrs = _start_tag(element, prefixes)
    if not len(element) and not element.text:
        return "<%s%s/>" % (tag, attrs)
    content = _escape(element.text or "") + "".join(_inline(c, prefixes) + _escape(c.tail or "") for c in element)
    return "<%s%s>%s</%s>" % (tag, attrs, content, tag)


def _write_element(element, indent, out, prefixes):
    children = list(element)
    if children and ((element.text or "").strip() or any((c.tail or "").strip() for c in children)):
        out.append(indent + _inline(element, prefixes))
        return
    tag, attrs = _start_tag(element, prefixes)
    text = (element.text or "").strip() if not children else ""
    if not children and not text:
        out.append("%s<%s%s/>" % (indent, tag, attrs))
    elif not children:
        out.append("%s<%s%s>%s</%s>" % (indent, tag, attrs, _escape(element.text), tag))
    else:
        out.append("%s<%s%s>" % (indent, tag, attrs))
        for child in children:
            _write_element(child, indent + "    ", out, prefixes)
        out.append("%s</%s>" % (indent, tag))


def _value_key(element):
    tag = element.tag
    if tag == "item":
        r_type = element.get("type")
    else:
        r_type = _VALUE_TYPES.get(tag)
    if r_type is None:
        raise ValueError("unsupported value resource <%s>" % tag)
    return r_type, element.get("name")


def merged_values(contents):
    """The values files of one directory as one file, the way AGP writes it into a library AAR."""
    elements = {}
    for content in contents:
        root = ET.fromstring(content)
        for element in root:
            if not isinstance(element.tag, str) or element.tag == "eat-comment":
                continue
            elements[_value_key(element)] = element
    prefixes = _Prefixes()
    lines = []
    for key in sorted(elements):
        _write_element(elements[key], "    ", lines, prefixes)
    lines = ['<?xml version="1.0" encoding="utf-8"?>', "<resources%s>" % prefixes.declarations()] + lines
    lines.append("</resources>")
    return "\n".join(lines).encode("utf-8")


def _r_name(name):
    return re.sub(r"[.:-]", "_", name)


# Resource directories whose XML files declare ids with "@+id/" attribute values (AGP's
# FolderTypeRelationship.isIdGeneratingFolderType).
_ID_DIRECTORIES = ("drawable", "layout", "menu", "navigation", "transition", "xml")


def _enum_ids(attr):
    """The ids of an attr's enum values. AGP's R.txt has them, but not those of flag values."""
    for value in attr:
        if (value.get("type") if value.tag == "item" else value.tag) == "enum":
            yield ("int", "id", _r_name(value.get("name")))


def platform_attrs(android_jar):
    """The ids of the platform's public attributes: the constants of android.R$attr."""
    with zipfile.ZipFile(android_jar) as zf:
        data = zf.read("android/R$attr.class")
    pos = 10
    pool = [None]
    count = struct.unpack_from(">H", data, 8)[0]
    while len(pool) < count:
        tag = data[pos]
        if tag == 1:
            length = struct.unpack_from(">H", data, pos + 1)[0]
            pool.append(data[pos + 3:pos + 3 + length].decode("utf-8"))
            pos += 3 + length
        elif tag == 3:
            pool.append(struct.unpack_from(">i", data, pos + 1)[0])
            pos += 5
        elif tag in (5, 6):
            pool += [None, None]
            pos += 9
        else:
            pool.append(None)
            pos += {4: 5, 7: 3, 8: 3, 9: 5, 10: 5, 11: 5, 12: 5, 15: 4, 16: 3, 17: 5, 18: 5, 19: 3, 20: 3}[tag]
    pos += 6
    pos += 2 + 2 * struct.unpack_from(">H", data, pos)[0]
    attrs = {}
    field_count = struct.unpack_from(">H", data, pos)[0]
    pos += 2
    for _ in range(field_count):
        name = pool[struct.unpack_from(">H", data, pos + 2)[0]]
        attribute_count = struct.unpack_from(">H", data, pos + 6)[0]
        pos += 8
        for _ in range(attribute_count):
            attribute, length = struct.unpack_from(">HI", data, pos)
            if pool[attribute] == "ConstantValue":
                attrs[name] = pool[struct.unpack_from(">H", data, pos + 6)[0]]
            pos += 6 + length
    return attrs


def _styleable_order(attr):
    """AGP orders a styleable's attributes by name, a platform one's spelled android_<name>."""
    return "android_" + attr[len("android:"):] if attr.startswith("android:") else attr


def symbols(res_files, platform):
    """R.txt of the library's own resources as AGP writes it into an AAR: placeholder ids, except
    the platform attributes of styleables, which keep theirs (`platform`, see platform_attrs)."""
    entries = set()
    styleables = {}
    for path, content in res_files.items():
        directory, file_name = path.split("/")[1:3]
        r_type = directory.split("-", 1)[0]
        if r_type != "values":
            entries.add(("int", r_type, _r_name(file_name.split(".", 1)[0])))
            if r_type in _ID_DIRECTORIES and file_name.endswith(".xml"):
                for element in ET.fromstring(content).iter():
                    for value in element.attrib.values():
                        if value.startswith("@+id/"):
                            entries.add(("int", "id", _r_name(value[len("@+id/"):])))
            continue
        for element in ET.fromstring(content):
            if not isinstance(element.tag, str) or element.tag == "eat-comment":
                continue
            r_type, name = _value_key(element)
            if r_type == "macro":
                continue
            if r_type == "styleable":
                attrs = []
                for a in element:
                    if a.tag != "attr":
                        continue
                    attr = a.get("name")
                    if attr.startswith("android:"):
                        if _r_name(attr[len("android:"):]) not in platform:
                            raise ValueError("%s in styleable %s is not a public platform attribute" % (attr, name))
                        attrs.append((attr, platform[_r_name(attr[len("android:"):])]))
                    else:
                        attrs.append((attr, 0))
                        entries.add(("int", "attr", _r_name(attr)))
                        entries.update(_enum_ids(a))
                styleables[_r_name(name)] = sorted(attrs, key=lambda a: _styleable_order(a[0]))
            else:
                entries.add(("int", r_type, _r_name(name)))
                if r_type == "attr":
                    entries.update(_enum_ids(element))
    lines = {}
    for e in entries:
        lines.setdefault(e[1], {})[e[2]] = ["%s %s %s 0x0" % e]
    for name, attrs in styleables.items():
        lines.setdefault("styleable", {})[name] = (
            ["int[] styleable %s { %s }" % (name, ", ".join("0x%x" % value for _, value in attrs))]
            + ["int styleable %s_%s %d" % (name, _r_name(attr), i) for i, (attr, _) in enumerate(attrs)]
        )
    out = [line for r_type in sorted(lines) for name in sorted(lines[r_type]) for line in lines[r_type][name]]
    return "".join(line + "\n" for line in out).encode("utf-8")


def aar_metadata(min_compile_sdk):
    return (
        "aarFormatVersion=1.0\n"
        "aarMetadataVersion=1.0\n"
        "minCompileSdk=%s\n"
        "minCompileMinorSdk=0\n"
        "minCompileSdkExtension=0\n"
        "minAndroidGradlePluginVersion=1.0.0\n"
        "coreLibraryDesugaringEnabled=false\n" % min_compile_sdk
    ).encode("utf-8")


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--classes", required=True)
    parser.add_argument("--resources_aar")
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--min_sdk", required=True)
    parser.add_argument("--min_compile_sdk", required=True)
    parser.add_argument("--android_jar", required=True)
    parser.add_argument("--proguard", action="append", default=[])
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)

    manifest = minimal_manifest(args.namespace, args.min_sdk)
    res, assets = {}, {}
    if args.resources_aar:
        with zipfile.ZipFile(args.resources_aar) as zf:
            for info in zf.infolist():
                if info.is_dir():
                    continue
                if info.filename == "AndroidManifest.xml":
                    manifest = with_min_sdk(zf.read(info).decode("utf-8"), args.min_sdk)
                elif info.filename.startswith("res/"):
                    res[info.filename] = zf.read(info)
                elif info.filename.startswith("assets/"):
                    assets[info.filename] = zf.read(info)

    packaged_res = {}
    values = {}
    for path, content in res.items():
        directory = path.split("/")[1]
        if directory.split("-", 1)[0] == "values":
            values.setdefault(directory, []).append(content)
        else:
            packaged_res[path] = content
    for directory, contents in values.items():
        packaged_res["res/%s/%s.xml" % (directory, directory)] = merged_values(contents)

    proguard = b"".join(open(p, "rb").read() for p in args.proguard)

    entries = [
        ("R.txt", symbols(res, platform_attrs(args.android_jar))),
        ("AndroidManifest.xml", manifest.encode("utf-8")),
        ("classes.jar", classes_jar(args.classes, args.namespace)),
    ]
    if args.proguard:
        entries.append(("proguard.txt", proguard))
    with zipfile.ZipFile(args.out, "w") as zf:
        written = set()

        def write(name, content):
            for d in _parents(name):
                if d not in written:
                    written.add(d)
                    zf.writestr(_zip_info(d, _AAR_TIME, is_dir=True), b"")
            zf.writestr(_zip_info(name, _AAR_TIME), content)

        for name, content in entries:
            zf.writestr(_zip_info(name, _AAR_TIME), content)
        for name in sorted(packaged_res, key=_path_order):
            write(name, packaged_res[name])
        zf.writestr(_zip_info("META-INF/com/android/build/gradle/aar-metadata.properties", _AAR_TIME), aar_metadata(args.min_compile_sdk))
        for name in sorted(assets, key=_path_order):
            write(name, assets[name])


if __name__ == "__main__":
    main(sys.argv[1:])
