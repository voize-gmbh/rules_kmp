import io
import struct
import unittest
import xml.etree.ElementTree as ET
import zipfile

import package_aar


class MergedValuesTest(unittest.TestCase):
    def test_namespaced_attributes_get_their_namespace_declared_on_the_root(self):
        merged = package_aar.merged_values([
            b'<resources xmlns:tools="http://schemas.android.com/tools">'
            b'<style name="Theme"><item name="android:windowContentTransitions" tools:ignore="NewApi">true</item></style>'
            b"</resources>",
        ])
        self.assertEqual(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<resources xmlns:ns1="http://schemas.android.com/tools">\n'
            '    <style name="Theme">\n'
            '        <item name="android:windowContentTransitions" ns1:ignore="NewApi">true</item>\n'
            "    </style>\n"
            "</resources>",
            merged.decode(),
        )
        ET.fromstring(merged)

    def test_styled_strings_keep_their_text(self):
        merged = package_aar.merged_values([
            b'<resources xmlns:xliff="urn:oasis:names:tc:xliff:document:1.2">'
            b'<string name="a">Tap <b>here</b> for <xliff:g id="n">%d</xliff:g> items</string>'
            b'<string name="b" xml:space="preserve"> x </string>'
            b"</resources>",
        ])
        self.assertEqual(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<resources xmlns:ns1="urn:oasis:names:tc:xliff:document:1.2">\n'
            '    <string name="a">Tap <b>here</b> for <ns1:g id="n">%d</ns1:g> items</string>\n'
            '    <string name="b" xml:space="preserve"> x </string>\n'
            "</resources>",
            merged.decode(),
        )


class SymbolsTest(unittest.TestCase):
    def test_enum_values_and_ids_declared_in_xml_files_are_ids_as_in_agp(self):
        r_txt = package_aar.symbols({
            "res/values/attrs.xml": (
                b"<resources>"
                b'<attr name="gradientType"><enum name="linear" value="0"/><enum name="radial" value="1"/></attr>'
                b'<attr name="scrollFlags"><flag name="scroll" value="0x1"/></attr>'
                b'<declare-styleable name="Chart"><attr name="mode"><enum name="bar.chart" value="0"/></attr>'
                b'<attr name="gradientType"/></declare-styleable>'
                b"</resources>"
            ),
            "res/layout/main.xml": (
                b'<FrameLayout xmlns:android="http://schemas.android.com/apk/res/android" android:id="@+id/root">'
                b'<TextView android:id="@+id/title" android:layout_below="@id/root"/></FrameLayout>'
            ),
            "res/anim/fade.xml": b'<alpha xmlns:android="http://schemas.android.com/apk/res/android" android:id="@+id/fade_id"/>',
        }, {})
        self.assertEqual(
            "int anim fade 0x0\n"
            "int attr gradientType 0x0\n"
            "int attr mode 0x0\n"
            "int attr scrollFlags 0x0\n"
            "int id bar_chart 0x0\n"
            "int id linear 0x0\n"
            "int id radial 0x0\n"
            "int id root 0x0\n"
            "int id title 0x0\n"
            "int layout main 0x0\n"
            "int[] styleable Chart { 0x0, 0x0 }\n"
            "int styleable Chart_gradientType 0\n"
            "int styleable Chart_mode 1\n",
            r_txt.decode(),
        )

    def test_styleables_are_ordered_and_platform_attributes_keep_their_ids_as_in_agp(self):
        # The expected R.txt is what AGP 9.5's library R.txt tasks write for these resources.
        r_txt = package_aar.symbols({
            "res/values/attrs.xml": (
                b"<resources>"
                b'<declare-styleable name="S"><attr name="androidA" format="string"/><attr name="android:textColor"/>'
                b'<attr name="Zed" format="string"/><attr name="a.b" format="string"/><attr name="a_a" format="string"/>'
                b'<attr name="refOnly"/></declare-styleable>'
                b'<macro name="m">@string/s</macro>'
                b'<string name="s">s</string>'
                b"</resources>"
            ),
            "res/xml/paths.xml": b"<paths/>",
        }, {"textColor": 0x1010098})
        self.assertEqual(
            "int attr Zed 0x0\n"
            "int attr a_a 0x0\n"
            "int attr a_b 0x0\n"
            "int attr androidA 0x0\n"
            "int attr refOnly 0x0\n"
            "int string s 0x0\n"
            "int[] styleable S { 0x0, 0x0, 0x0, 0x0, 0x1010098, 0x0 }\n"
            "int styleable S_Zed 0\n"
            "int styleable S_a_b 1\n"
            "int styleable S_a_a 2\n"
            "int styleable S_androidA 3\n"
            "int styleable S_android_textColor 4\n"
            "int styleable S_refOnly 5\n"
            "int xml paths 0x0\n",
            r_txt.decode(),
        )

    def test_a_platform_attribute_that_is_not_public_fails(self):
        with self.assertRaises(ValueError):
            package_aar.symbols({"res/values/a.xml": b'<resources><declare-styleable name="S"><attr name="android:x"/></declare-styleable></resources>'}, {})


class PlatformAttrsTest(unittest.TestCase):
    def test_reads_the_constants_of_android_r_attr(self):
        def utf8(text):
            return b"\x01" + struct.pack(">H", len(text)) + text

        pool = [
            utf8(b"android/R$attr"), b"\x07" + struct.pack(">H", 1),
            utf8(b"java/lang/Object"), b"\x07" + struct.pack(">H", 3),
            utf8(b"background"), utf8(b"I"), utf8(b"ConstantValue"),
            b"\x03" + struct.pack(">i", 0x10100D4),
            b"\x05" + struct.pack(">q", 7),
            utf8(b"textColor"), b"\x03" + struct.pack(">i", 0x1010098),
        ]

        def field(name, value):
            return struct.pack(">HHHH", 0x19, name, 6, 1) + struct.pack(">HIH", 7, 2, value)

        class_file = (
            b"\xca\xfe\xba\xbe" + struct.pack(">HHH", 0, 52, 13) + b"".join(pool)
            + struct.pack(">HHHH", 0x21, 2, 4, 0) + struct.pack(">H", 2) + field(5, 8) + field(11, 12)
            + struct.pack(">HH", 0, 0)
        )
        jar = io.BytesIO()
        with zipfile.ZipFile(jar, "w") as zf:
            zf.writestr("android/R$attr.class", class_file)
        self.assertEqual({"background": 0x10100D4, "textColor": 0x1010098}, package_aar.platform_attrs(jar))


if __name__ == "__main__":
    unittest.main()
