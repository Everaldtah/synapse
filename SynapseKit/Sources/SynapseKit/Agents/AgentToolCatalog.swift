import Foundation

/// The tools that let an agent use the app itself: the workspace, the graph view, navigation, files and other agents.
/// (Web, shell, Claude Code and attached sources are in `AgentToolSpec`.)
public extension AgentToolSpec {
    // MARK: Reading

    static let listPages = AgentToolSpec(
        name: "list_pages",
        summary: "List pages and databases (title, kind, parent, tags). Optional input: words to filter titles by.",
        example: "<tool name=\"list_pages\"/>", inputOptional: true)

    static let searchWorkspace = AgentToolSpec(
        name: "search_workspace",
        summary: "Find the user's pages about something; returns the best matches with excerpts.",
        example: "<tool name=\"search_workspace\">project deadlines</tool>")

    static let readPage = AgentToolSpec(
        name: "read_page",
        summary: "Read a page as Markdown (a database: its columns and rows; a row: its properties).",
        example: "<tool name=\"read_page\">Weekly review</tool>")

    // MARK: Changing

    static let createPage = AgentToolSpec(
        name: "create_page",
        summary: "Create a page from Markdown. parent (a page title) and icon (an emoji) are optional. Connect it with [[Page]] links and #tags.",
        example: "<tool name=\"create_page\" title=\"Photosynthesis\" parent=\"Biology\" icon=\"🌱\">## Overview\nPlants turn light into sugar using [[Chlorophyll]]. #biology</tool>",
        changes: true)

    static let editPage = AgentToolSpec(
        name: "edit_page",
        summary: "Add Markdown to a page: mode=\"append\" (default) or \"prepend\"; mode=\"replace\" rewrites the whole page.",
        example: "<tool name=\"edit_page\" title=\"Photosynthesis\" mode=\"append\">## Light reactions\n- Happen in the thylakoids</tool>",
        changes: true)

    static let renamePage = AgentToolSpec(
        name: "rename_page",
        summary: "Rename a page (links to it are updated). Input: the new title.",
        example: "<tool name=\"rename_page\" title=\"Untitled\">Reading notes</tool>", changes: true)

    static let movePage = AgentToolSpec(
        name: "move_page",
        summary: "Put a page under another page. Input: the new parent's title, or \"top\" for the top level.",
        example: "<tool name=\"move_page\" title=\"Chlorophyll\">Biology</tool>", changes: true)

    static let deletePage = AgentToolSpec(
        name: "delete_page",
        summary: "Move a page to the Trash (it can be restored). Only when the user asked.",
        example: "<tool name=\"delete_page\">Scratch notes</tool>", changes: true)

    static let linkPages = AgentToolSpec(
        name: "link_pages",
        summary: "Link one page to others with [[links]] (edges in the graph). Input: titles separated by commas; missing pages are created.",
        example: "<tool name=\"link_pages\" from=\"Photosynthesis\">Chlorophyll, Calvin cycle</tool>", changes: true)

    static let tagPage = AgentToolSpec(
        name: "tag_page",
        summary: "Add #tags to a page. Input: tags separated by commas.",
        example: "<tool name=\"tag_page\" title=\"Photosynthesis\">biology, plants</tool>", changes: true)

    static let createDatabase = AgentToolSpec(
        name: "create_database",
        summary: "Create a database (a table of pages). Input: one column per line as Name: type. Types: title, text, number, select(a, b), multi_select(a, b), status, date, checkbox, url, email, phone.",
        example: "<tool name=\"create_database\" title=\"Reading list\">Title: title\nAuthor: text\nGenre: select(Fiction, Science)\nRating: number\nFinished: date</tool>",
        changes: true)

    static let addRows = AgentToolSpec(
        name: "add_rows",
        summary: "Add rows to a database. Input: CSV with a header row of column names (new columns are added as text).",
        example: "<tool name=\"add_rows\" database=\"Reading list\">Title,Author,Genre,Rating\nDune,Frank Herbert,Fiction,5</tool>",
        changes: true)

    static let updateRow = AgentToolSpec(
        name: "update_row",
        summary: "Change a database row's properties. Input: one Column: value per line.",
        example: "<tool name=\"update_row\" database=\"Reading list\" row=\"Dune\">Rating: 4\nFinished: 2026-10-20</tool>",
        changes: true)

    static let dailyNote = AgentToolSpec(
        name: "daily_note",
        summary: "Today's daily note: returns it, and appends the input (Markdown) if any.",
        example: "<tool name=\"daily_note\">- [ ] Call the bank</tool>", inputOptional: true, changes: true)

    // MARK: Graph

    static let graphOverview = AgentToolSpec(
        name: "graph_overview",
        summary: "Graph statistics: pages, links, hubs, orphans, tags, and pages that mention each other without a link.",
        example: "<tool name=\"graph_overview\"/>", inputOptional: true)

    static let graphSettings = AgentToolSpec(
        name: "graph_settings",
        summary: "Show the graph view's settings (filters, colour groups, display, forces).",
        example: "<tool name=\"graph_settings\"/>", inputOptional: true)

    static let setGraph = AgentToolSpec(
        name: "set_graph",
        summary: "Change graph view settings, as attributes or key: value lines. Keys: show_tags, show_unresolved, show_orphans, show_rows, show_daily, show_hierarchy, show_relations, depth, search, color_by (type|tag|groups), node_size, link_thickness, label_zoom, arrows, center_force, repel_force, link_force, link_distance.",
        example: "<tool name=\"set_graph\" show_tags=\"true\" color_by=\"groups\" repel_force=\"600\"/>", inputOptional: true)

    static let graphGroup = AgentToolSpec(
        name: "graph_group",
        summary: "Colour a group of nodes in the graph. Input: a query — tag:name, path:Parent page, kind:database|row|daily|page, title:words, line:text, or plain words. color: gray, brown, orange, yellow, green, blue, purple, pink, red; color=\"none\" removes the group; input \"clear\" removes all.",
        example: "<tool name=\"graph_group\" color=\"green\">tag:biology</tool>")

    static let showGraph = AgentToolSpec(
        name: "show_graph",
        summary: "Open the graph in the app. focus (a page title) shows its local graph, depth = links away (1-5).",
        example: "<tool name=\"show_graph\" focus=\"Photosynthesis\" depth=\"2\"/>", inputOptional: true)

    // MARK: App

    static let openInApp = AgentToolSpec(
        name: "open",
        summary: "Open a page in the app, or a tab: home, search, graph, agents, settings.",
        example: "<tool name=\"open\">Reading list</tool>")

    // MARK: Files

    static let createSpreadsheet = AgentToolSpec(
        name: "create_spreadsheet",
        summary: "Make an Excel file (.xlsx). Input: CSV or a Markdown table; start each extra sheet with a line ### Sheet: Name. Cells starting with = are formulas. Optional page=\"Title\" also attaches it to that page.",
        example: "<tool name=\"create_spreadsheet\" title=\"Budget\">### Sheet: Costs\nItem,Amount\nRent,1200\nFood,300\nTotal,=SUM(B2:B3)</tool>")

    static let createPresentation = AgentToolSpec(
        name: "create_presentation",
        summary: "Make a PowerPoint deck (.pptx). Slides are separated by a line ---; each has a # title, - bullets (indent for sub-bullets) and optional Notes: speaker notes. theme: light, dark, ocean, sunset, forest, mono.",
        example: "<tool name=\"create_presentation\" title=\"Photosynthesis\" theme=\"ocean\"># Photosynthesis\nHow plants make food\n---\n# Light reactions\n- Happen in the thylakoids\n- Make ATP and NADPH\nNotes: Mention chlorophyll.</tool>")

    static let createDocument = AgentToolSpec(
        name: "create_document",
        summary: "Make a Word document (.docx) from Markdown (headings, lists, tables, bold, italic).",
        example: "<tool name=\"create_document\" title=\"Project brief\"># Project brief\n## Goals\n- Ship v1 by March</tool>")

    static let createPDF = AgentToolSpec(
        name: "create_pdf",
        summary: "Make a PDF from Markdown (headings, lists, tables, bold, italic).",
        example: "<tool name=\"create_pdf\" title=\"Trip itinerary\"># Lisbon, 3 days\n## Day 1\n- Alfama walk</tool>")

    static let exportPage = AgentToolSpec(
        name: "export_page",
        summary: "Save an existing page as a file: format pdf, docx, pptx (one slide per heading), xlsx (a database's rows) or md.",
        example: "<tool name=\"export_page\" format=\"pdf\">Weekly review</tool>")

    static let saveFile = AgentToolSpec(
        name: "save_file",
        summary: "Bring a file the shell made into Synapse so the user can open and share it. Input: its path; where=\"iphone\" or \"pc\" as for shell.",
        example: "<tool name=\"save_file\" where=\"pc\">out/chart.png</tool>")

    // MARK: Browser

    /// The built-in browser. The app runs it (WebKit) and shows the user the screen.
    static let browser = AgentToolSpec(
        name: "browser",
        summary: """
        Use the built-in web browser like a person would; the user watches the screen. One action per call. After         every call you get the page's title, URL, a numbered map of what can be clicked or typed into, and the         visible text. Actions (attribute action): open (input: a URL, or words to search for), click (input: an         element number from the map, or the text of a link/button), type (target="number", input: the text; add         submit="true" to press Enter afterwards), key (input: Enter, Escape, Tab, Backspace), scroll (input: down, up,         top, bottom, or an element number), read (no input: the whole page's text; input: words to find on the         page), back, wait (input: seconds). Examples: <tool name="browser" action="type" target="3"         submit="true">weather in Lisbon</tool>  <tool name="browser" action="click">7</tool>  <tool name="browser"         action="scroll">down</tool>. Use the browser when the user wants something done or checked on a website;         web_search is only for quick facts.
        """,
        example: "<tool name=\"browser\" action=\"open\">https://en.wikipedia.org</tool>")

    /// The same tool for small models: fewer words, the same actions.
    static let browserSmall = AgentToolSpec(
        name: "browser",
        summary: """
        Web browser the user watches. action="open" (URL or search words), "click" (element number), "type"         (target="number", the text; submit="true" presses Enter), "scroll" (down/up), "read", "back". Each call returns         the page's numbered elements and text. E.g. <tool name="browser" action="type" target="3" submit="true">weather         in Lisbon</tool>
        """,
        example: "<tool name=\"browser\" action=\"open\">https://en.wikipedia.org</tool>")

    // MARK: Other agents

    static func askAgent(_ names: [String]) -> AgentToolSpec {
        AgentToolSpec(
            name: "ask_agent",
            summary: "Give a self-contained sub-task to another agent and get its answer. Agents: \(names.joined(separator: ", ")).",
            example: "<tool name=\"ask_agent\" agent=\"\(names.first ?? "Researcher")\">Find three recent sources on CRISPR base editing, with links.</tool>")
    }
}

public enum AgentToolCatalog {
    /// The app tools for a set of capabilities, in the order the model should see them. Web, shell, Claude Code and
    /// delegation depend on what's set up, so the app adds those itself.
    public static func appTools(for capabilities: Set<AgentCapability>, small: Bool = false) -> [AgentToolSpec] {
        var t: [AgentToolSpec] = []
        if capabilities.contains(.readWorkspace) || capabilities.contains(.editWorkspace) {
            t += [.listPages, .searchWorkspace, .readPage]
        }
        if capabilities.contains(.editWorkspace) {
            t += small ? [.createPage, .editPage, .linkPages, .tagPage]
                : [.createPage, .editPage, .renamePage, .movePage, .deletePage, .linkPages, .tagPage,
                   .createDatabase, .addRows, .updateRow, .dailyNote]
        }
        if capabilities.contains(.graph) {
            t += small ? [.graphOverview, .setGraph, .graphGroup, .showGraph]
                : [.graphOverview, .graphSettings, .setGraph, .graphGroup, .showGraph]
        }
        if capabilities.contains(.navigate) { t.append(.openInApp) }
        // Small models get the browser only when it's what the agent is for (see AgentToolbox), so the tool lists
        // small models were tuned on don't change.
        if capabilities.contains(.browser) && !small { t.append(.browser) }
        if capabilities.contains(.documents) {
            t += small ? [.createSpreadsheet, .createPresentation, .createPDF]
                : [.createSpreadsheet, .createPresentation, .createDocument, .createPDF, .exportPage]
        }
        return t
    }

    /// The system prompt for an agent run.
    public static func system(for agent: AgentProfile, workspaceName: String, today: Date = Date(), small: Bool = false) -> String {
        var s = small ? "You are \(agent.name), an assistant inside Synapse, a notes app." : """
        You are \(agent.name), an AI agent inside Synapse, a notes, docs and databases app with an Obsidian-style \
        graph of linked pages. The user's workspace is "\(AIPrompts.escape(workspaceName))". Today is \(DateText.long(today)).
        Pages use Markdown: headings (#), lists (-, 1.), to-dos (- [ ]), quotes (>), callouts (> [!note]), code fences, \
        tables, **bold**, *italic*, ==highlight==, [[Page links]] and #tags. A [[link]] or a shared #tag is an edge in \
        the graph.
        """
        let extra = agent.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { s += "\n\n" + extra }
        if !small {
            s += """


            Work in steps with your tools and keep going until the task is done. Refer to pages by their exact titles. \
            When you changed the workspace or made files, end with a short summary of what you did and the [[Page]] \
            titles involved. Reply in the user's language.
            """
        }
        return s
    }
}

/// Model keys stored with agents and chats: "" (Auto), "local:<card id>", "cloud:<provider>:<model>",
/// "harness:<model>", "api:<provider id>:<model id>".
public enum AgentModelKey {
    public static func parts(_ key: String) -> (kind: String, a: String, b: String) {
        let p = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        return (p.first ?? "", p.count > 1 ? p[1] : "", p.count > 2 ? p[2] : "")
    }
}
