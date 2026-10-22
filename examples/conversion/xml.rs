use super::{Failure, Result, require, xml_chars};
use quick_xml::{Reader, events::Event};
use std::collections::BTreeMap;
#[derive(Debug, Clone)]
pub struct Node {
    pub name: String,
    pub attrs: BTreeMap<String, String>,
    pub children: Vec<Node>,
    pub text: String,
    pub offset: u64,
}
impl Node {
    pub fn attr(&self, key: &str) -> Result<&str> {
        self.attrs.get(key).map(String::as_str).ok_or_else(|| {
            Failure::new("missing_xml_attribute").detail(
                serde_json::json!({"element":self.name,"key":key,"byte_offset":self.offset}),
            )
        })
    }
    pub fn attrs_only(&self, allowed: &[&str]) -> Result<()> {
        require(
            self.attrs.keys().all(|key| allowed.contains(&key.as_str())),
            "unsupported_xml_attribute",
        )
    }
    pub fn structural(&self) -> Result<()> {
        require(self.text.trim().is_empty(), "unsupported_xml_text")
    }
}
pub fn parse(input: &[u8]) -> Result<Node> {
    let mut reader = Reader::from_reader(input);
    reader.config_mut().check_end_names = true;
    let mut stack: Vec<Node> = Vec::new();
    let mut root = None;
    let mut count = 0_usize;
    loop {
        let offset = reader.buffer_position();
        match reader
            .read_event()
            .map_err(|_| Failure::new("malformed_xml"))?
        {
            Event::Start(tag) | Event::Empty(tag) => {
                // Reader's current event type is recoverable from its original closing bytes.
                let end = reader.buffer_position() as usize;
                let empty = input[..end].ends_with(b"/>");
                let name = std::str::from_utf8(tag.name().as_ref())
                    .map_err(|_| Failure::new("xml_name"))?
                    .to_owned();
                require(!name.contains(':'), "unsupported_xml_namespace")?;
                let mut attrs = BTreeMap::new();
                for attr in tag.attributes() {
                    let attr = attr.map_err(|_| Failure::new("duplicate_xml_attribute"))?;
                    let key = std::str::from_utf8(attr.key.as_ref())
                        .map_err(|_| Failure::new("xml_name"))?
                        .to_owned();
                    require(
                        !attr
                            .value
                            .iter()
                            .any(|b| matches!(b, b'\r' | b'\n' | b'\t')),
                        "literal_xml_attribute_whitespace",
                    )?;
                    let value = attr
                        .decode_and_unescape_value(reader.decoder())
                        .map_err(|_| Failure::new("xml_reference_unsupported"))?
                        .into_owned();
                    require(xml_chars(&value), "xml10_character")?;
                    require(
                        attrs.insert(key, value).is_none(),
                        "duplicate_xml_attribute",
                    )?;
                }
                count += 1;
                require(count <= 500000 && stack.len() < 32, "xml_complexity_limit")?;
                let node = Node {
                    name,
                    attrs,
                    children: Vec::new(),
                    text: String::new(),
                    offset,
                };
                if empty {
                    attach(node, &mut stack, &mut root)?;
                } else {
                    stack.push(node);
                }
            }
            Event::End(_) => {
                let node = stack.pop().ok_or_else(|| Failure::new("malformed_xml"))?;
                attach(node, &mut stack, &mut root)?;
            }
            Event::Text(text) => {
                let value = text
                    .unescape()
                    .map_err(|_| Failure::new("xml_reference_unsupported"))?;
                require(xml_chars(&value), "xml10_character")?;
                if let Some(node) = stack.last_mut() {
                    node.text.push_str(&value);
                } else {
                    require(value.trim().is_empty(), "malformed_xml")?;
                }
            }
            Event::Decl(decl) => {
                require(stack.is_empty() && root.is_none(), "malformed_xml")?;
                require(
                    decl.version()
                        .map_err(|_| Failure::new("malformed_xml"))?
                        .as_ref()
                        == b"1.0",
                    "xml10_required",
                )?;
                if let Some(encoding) = decl.encoding() {
                    require(
                        encoding
                            .map_err(|_| Failure::new("xml_encoding"))?
                            .as_ref()
                            .eq_ignore_ascii_case(b"UTF-8"),
                        "utf8_required",
                    )?;
                }
            }
            Event::Comment(_) => {}
            Event::DocType(_) | Event::PI(_) | Event::CData(_) => {
                return Err(Failure::new("xml_declaration_unsupported"));
            }
            Event::Eof => break,
        }
    }
    require(stack.is_empty(), "malformed_xml")?;
    root.ok_or_else(|| Failure::new("malformed_xml"))
}
fn attach(node: Node, stack: &mut [Node], root: &mut Option<Node>) -> Result<()> {
    if let Some(parent) = stack.last_mut() {
        parent.children.push(node);
    } else {
        require(root.is_none(), "multiple_xml_roots")?;
        *root = Some(node);
    }
    Ok(())
}
pub fn escape(value: &str) -> String {
    let mut result = String::new();
    for c in value.chars() {
        match c {
            '&' => result.push_str("&amp;"),
            '<' => result.push_str("&lt;"),
            '>' => result.push_str("&gt;"),
            '"' => result.push_str("&quot;"),
            '\'' => result.push_str("&apos;"),
            '\n' => result.push_str("&#10;"),
            '\r' => result.push_str("&#13;"),
            '\t' => result.push_str("&#9;"),
            _ => result.push(c),
        }
    }
    result
}
