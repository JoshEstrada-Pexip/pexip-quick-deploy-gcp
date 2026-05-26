import urllib.request
import re
import os
from urllib.parse import urljoin, urlparse
from html.parser import HTMLParser

# 1. Define URL Map
URL_MAP = {
    "https://docs.pexip.com/admin/integrate_api.htm": "management_api/integrate_api.md",
    "https://docs.pexip.com/api_manage/management_intro.htm": "management_api/management_intro.md",
    "https://docs.pexip.com/api_manage/using.htm": "management_api/using.md",
    "https://docs.pexip.com/api_manage/api_configuration.htm": "management_api/api_configuration.md",
    "https://docs.pexip.com/api_manage/api_status.htm": "management_api/api_status.md",
    "https://docs.pexip.com/api_manage/api_history.htm": "management_api/api_history.md",
    "https://docs.pexip.com/api_manage/api_command.htm": "management_api/api_command.md",
    "https://docs.pexip.com/api_manage/api_resource_details.htm": "management_api/api_resource_details.md",
    "https://docs.pexip.com/api_manage/extract_analyse.htm": "management_api/extract_analyse.md",
    "https://docs.pexip.com/api_manage/logs.htm": "management_api/logs.md",
    "https://docs.pexip.com/api_manage/api_with_snmp.htm": "management_api/api_with_snmp.md",
    "https://docs.pexip.com/admin/managing_API_oauth.htm": "management_api/managing_API_oauth.md",
    "https://docs.pexip.com/admin/integrate_api_client.htm": "client_apis/integrate_api_client.md",
    "https://docs.pexip.com/api_client/api_rest.htm": "client_apis/api_rest.md",
    "https://docs.pexip.com/api_client/api_pexrtc.htm": "client_apis/api_pexrtc.md",
    "https://docs.pexip.com/admin/api_event_sink.htm": "event_sink_api/api_event_sink.md",
    "https://docs.pexip.com/admin/event_sink.htm": "event_sink_api/event_sink.md",
    "https://docs.pexip.com/admin/external_policy.htm": "policy_api/external_policy.md",
}


def get_relative_md_link(current_md_path, target_md_path):
    curr_parts = current_md_path.split("/")
    tgt_parts = target_md_path.split("/")

    if len(curr_parts) == 2 and len(tgt_parts) == 2:
        if curr_parts[0] == tgt_parts[0]:
            return tgt_parts[1]
        return f"../{tgt_parts[0]}/{tgt_parts[1]}"
    if len(curr_parts) == 1 and len(tgt_parts) == 2:
        return f"{tgt_parts[0]}/{tgt_parts[1]}"
    return target_md_path


class FlareHTMLToMarkdown(HTMLParser):
    def __init__(self, current_url):
        super().__init__()
        self.current_url = current_url
        self.current_md_path = URL_MAP[current_url]
        self.output = []
        self.backup_output = []
        self.in_main_content = False
        self.depth_in_main = 0

        # Formatting states
        self.in_pre = False
        self.in_code = False
        self.in_strong = False
        self.in_em = False
        self.list_stack = []  # list of ('ul' or 'ol', count)

        # Table states
        self.in_table = False
        self.table_rows = []
        self.current_row = []
        self.current_cell = []
        self.in_cell = False

        # Link states
        self.current_link_url = None
        self.current_link_text = []

    def handle_starttag(self, tag, attrs):
        attrs_dict = dict(attrs)

        # Check main content boundary
        if tag == "div" and attrs_dict.get("id") == "mc-main-content":
            self.in_main_content = True
            self.depth_in_main = 1
            return

        # Target buffer selection
        buf = self.output if self.in_main_content else self.backup_output

        if tag == "div" and self.in_main_content:
            self.depth_in_main += 1

        # Skip specific Flare non-content divs
        cls = attrs_dict.get("class", "")
        if "topicToolbarProxy" in cls or "MCMiniTocBox" in cls or "breadcrumbs" in cls:
            return

        if self.in_pre:
            return

        if tag == "pre":
            self.in_pre = True
            buf.append("\n\n```")
            cls = attrs_dict.get("class", "").lower()
            if "json" in cls:
                buf.append("json")
            elif "python" in cls:
                buf.append("python")
            elif "xml" in cls:
                buf.append("xml")
            elif "html" in cls:
                buf.append("html")
            elif "bash" in cls or "shell" in cls:
                buf.append("bash")
            buf.append("\n")

        elif tag == "code":
            self.in_code = True
            if not self.in_pre:
                buf.append("`")

        elif tag in ("strong", "b"):
            self.in_strong = True
            buf.append("**")

        elif tag in ("em", "i"):
            self.in_em = True
            buf.append("*")

        elif tag in ("h1", "h2", "h3", "h4", "h5", "h6"):
            level = int(tag[1])
            buf.append("\n\n" + "#" * level + " ")

        elif tag == "p":
            buf.append("\n\n")

        elif tag == "br":
            if self.in_table:
                self.current_cell.append(" ")
            else:
                buf.append("  \n")

        elif tag in ("ul", "ol"):
            self.list_stack.append((tag, 0))
            buf.append("\n")

        elif tag == "li":
            if self.list_stack:
                indent = "    " * (len(self.list_stack) - 1)
                list_type, count = self.list_stack[-1]
                count += 1
                self.list_stack[-1] = (list_type, count)
                if list_type == "ol":
                    buf.append(f"{indent}{count}. ")
                else:
                    buf.append(f"{indent}- ")

        elif tag == "table":
            self.in_table = True
            self.table_rows = []

        elif tag == "tr":
            if self.in_table:
                self.current_row = []

        elif tag in ("td", "th"):
            if self.in_table:
                self.in_cell = True
                self.current_cell = []

        elif tag == "a" and "href" in attrs_dict:
            href = attrs_dict["href"]
            abs_url = urljoin(self.current_url, href)
            parsed = urlparse(abs_url)
            clean_url = f"{parsed.scheme}://{parsed.netloc}{parsed.path}"

            if clean_url in URL_MAP:
                target_md = URL_MAP[clean_url]
                local_link = get_relative_md_link(self.current_md_path, target_md)
                if parsed.fragment:
                    local_link += f"#{parsed.fragment}"
                self.current_link_url = local_link
            else:
                if clean_url.startswith("https://docs.pexip.com"):
                    self.current_link_url = abs_url
                else:
                    self.current_link_url = href
            self.current_link_text = []

        elif tag == "img" and "src" in attrs_dict:
            src = attrs_dict["src"]
            abs_img_url = urljoin(self.current_url, src)
            alt = attrs_dict.get("alt", "image")
            buf.append(f"![{alt}]({abs_img_url})")

    def handle_endtag(self, tag):
        if tag == "div" and self.in_main_content:
            self.depth_in_main -= 1
            if self.depth_in_main == 0:
                self.in_main_content = False
            return

        buf = self.output if self.in_main_content else self.backup_output

        if self.in_pre:
            if tag == "pre":
                self.in_pre = False
                buf.append("```\n\n")
            return

        if tag == "code":
            self.in_code = False
            if not self.in_pre:
                buf.append("`")

        elif tag in ("strong", "b"):
            self.in_strong = False
            buf.append("**")

        elif tag in ("em", "i"):
            self.in_em = False
            buf.append("*")

        elif tag in ("ul", "ol"):
            if self.list_stack:
                self.list_stack.pop()
            buf.append("\n")

        elif tag == "table":
            if self.in_table:
                table_str = self.render_table(self.table_rows)
                buf.append(table_str)
                self.in_table = False
                self.table_rows = []

        elif tag == "tr":
            if self.in_table:
                self.table_rows.append(self.current_row)
                self.current_row = []

        elif tag in ("td", "th"):
            if self.in_table:
                self.in_cell = False
                cell_text = (
                    "".join(self.current_cell)
                    .strip()
                    .replace("\n", " ")
                    .replace("|", "\\|")
                )
                self.current_row.append(cell_text)
                self.current_cell = []

        elif tag == "a":
            if self.current_link_url:
                link_text = "".join(self.current_link_text).strip()
                if not link_text:
                    link_text = self.current_link_url
                buf.append(f"[{link_text}]({self.current_link_url})")
                self.current_link_url = None
                self.current_link_text = []

    def handle_data(self, data):
        buf = self.output if self.in_main_content else self.backup_output
        if self.in_pre:
            buf.append(data)
        elif self.in_table and self.in_cell:
            self.current_cell.append(data)
        elif self.current_link_url is not None:
            self.current_link_text.append(data)
        else:
            clean_data = re.sub(r"\s+", " ", data)
            if buf and buf[-1].endswith("# "):
                clean_data = clean_data.lstrip()
            buf.append(clean_data)

    def render_table(self, rows):
        if not rows:
            return ""
        max_cols = max(len(r) for r in rows)
        if max_cols == 0:
            return ""

        markdown_rows = []
        padded_rows = []
        for r in rows:
            padded_rows.append(r + [""] * (max_cols - len(r)))

        header = padded_rows[0]
        markdown_rows.append("\n\n| " + " | ".join(header) + " |")

        separator = ["---"] * max_cols
        markdown_rows.append("| " + " | ".join(separator) + " |")

        for r in padded_rows[1:]:
            markdown_rows.append("| " + " | ".join(r) + " |")

        markdown_rows.append("\n\n")
        return "\n".join(markdown_rows)

    def get_markdown(self):
        target = self.output if self.output else self.backup_output
        full_text = "".join(target)
        full_text = re.sub(r"\n{3,}", "\n\n", full_text)
        return full_text.strip()


def scrape_page(url, dest_dir):
    print(f"Fetching: {url}")
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req) as response:
            html = response.read().decode("utf-8")
    except Exception as e:
        print(f"Error fetching {url}: {e}")
        return False

    parser = FlareHTMLToMarkdown(url)
    parser.feed(html)
    markdown_content = parser.get_markdown()

    # Save output file
    rel_path = URL_MAP[url]
    out_file = os.path.join(dest_dir, rel_path)
    os.makedirs(os.path.dirname(out_file), exist_ok=True)

    # Prepend original source reference
    header = f"<!-- Source: {url} -->\n"
    title_search = re.search(r"<title>(.*?)</title>", html, re.IGNORECASE)
    if title_search:
        title = title_search.group(1).replace(" | Pexip Infinity Docs", "").strip()
        header += f"# {title}\n\n"

    with open(out_file, "w", encoding="utf-8") as f:
        f.write(header + markdown_content)

    print(f"Saved: {out_file} ({len(markdown_content)} chars)")
    return True


def main():
    # Set output directory relative to repository root
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(script_dir)
    dest_dir = os.path.join(repo_root, "temp-pexip-docs")
    os.makedirs(dest_dir, exist_ok=True)

    success_count = 0
    for url in URL_MAP.keys():
        if scrape_page(url, dest_dir):
            success_count += 1

    print(f"\nCompleted! Successfully scraped {success_count}/{len(URL_MAP)} pages.")


if __name__ == "__main__":
    main()
