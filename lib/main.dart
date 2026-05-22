import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xml/xml.dart';

void main() {
  runApp(const PaperReaderApp());
}

class PaperReaderApp extends StatelessWidget {
  const PaperReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CVPR Reader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B7285)),
        useMaterial3: true,
      ),
      home: const PaperReaderPage(),
    );
  }
}

enum SortMode { relevance, latest }

class Paper {
  const Paper({
    required this.id,
    required this.title,
    required this.abstractText,
    required this.authors,
    required this.url,
    required this.publishedDate,
    required this.updatedDate,
    this.comments,
    this.affiliations,
    this.acceptanceStatus,
  });

  final String id;
  final String title;
  final String abstractText;
  final List<String> authors;
  final String url;
  final DateTime? publishedDate;
  final DateTime? updatedDate;
  final String? comments;
  final List<String>? affiliations;
  final String? acceptanceStatus;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'title': title,
      'abstractText': abstractText,
      'authors': authors,
      'url': url,
      'publishedDate': publishedDate?.toIso8601String(),
      'updatedDate': updatedDate?.toIso8601String(),
      'comments': comments,
      'affiliations': affiliations,
      'acceptanceStatus': acceptanceStatus,
    };
  }

  static Paper fromJson(Map<String, dynamic> json) {
    return Paper(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      abstractText: json['abstractText'] as String? ?? '',
      authors: (json['authors'] as List<dynamic>? ?? <dynamic>[])
          .map((dynamic e) => e.toString())
          .toList(),
      url: json['url'] as String? ?? '',
      publishedDate: json['publishedDate'] == null
          ? null
          : DateTime.tryParse(json['publishedDate'] as String),
      updatedDate: json['updatedDate'] == null
          ? null
          : DateTime.tryParse(json['updatedDate'] as String),
      comments: json['comments'] as String?,
      affiliations: (json['affiliations'] as List<dynamic>?)
          ?.map((dynamic e) => e.toString())
          .toList(),
      acceptanceStatus: json['acceptanceStatus'] as String?,
    );
  }
}

class ArxivService {
  static const String _httpsBaseUrl = 'https://export.arxiv.org/api/query';
  static const String _httpBaseUrl = 'http://export.arxiv.org/api/query';
  static const Map<String, String> _headers = <String, String>{
    'User-Agent': 'ppread-demo1/1.0 (Flutter; cs.CV reader)',
    'Accept': 'application/atom+xml',
  };

  Future<List<Paper>> fetchCvprPapers({
    required String keyword,
    required SortMode sortMode,
    int maxResults = 30,
  }) async {
    final String query = keyword.trim().isEmpty
        ? 'cat:cs.CV'
        : 'cat:cs.CV+AND+all:${Uri.encodeQueryComponent(keyword.trim())}';
    final String queryString =
        '?search_query=$query&start=0&max_results=$maxResults&sortBy=${_mapSort(sortMode)}&sortOrder=descending';
    final http.Response response = await _requestWithFallback(queryString);

    final XmlDocument document = XmlDocument.parse(response.body);
    final Iterable<XmlElement> entries = document.findAllElements('entry');
    return entries.map(_parseEntry).where((Paper p) => p.id.isNotEmpty).toList();
  }

  Future<http.Response> _requestWithFallback(String queryString) async {
    final List<Uri> endpoints = <Uri>[
      Uri.parse('$_httpsBaseUrl$queryString'),
      Uri.parse('$_httpBaseUrl$queryString'),
    ];
    Object? lastError;

    for (final Uri uri in endpoints) {
      try {
        for (int attempt = 0; attempt < 3; attempt++) {
          final http.Response response = await http.get(uri, headers: _headers);
          if (response.statusCode == 200) {
            return response;
          }
          if (response.statusCode == 429 && attempt < 2) {
            final int waitSeconds = pow(2, attempt + 1).toInt();
            await Future<void>.delayed(Duration(seconds: waitSeconds));
            continue;
          }
          lastError = Exception('arXiv request failed (${response.statusCode}) for $uri');
          break;
        }
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception('Could not connect to arXiv: $lastError');
  }

  String _mapSort(SortMode mode) {
    switch (mode) {
      case SortMode.relevance:
        return 'relevance';
      case SortMode.latest:
        return 'submittedDate';
    }
  }

  Paper _parseEntry(XmlElement entry) {
    final String id = _text(entry, 'id');
    final String title = _normalize(_text(entry, 'title'));
    final String summary = _normalize(_text(entry, 'summary'));
    final List<String> authors = entry
        .findElements('author')
        .map((XmlElement authorNode) => _normalize(_text(authorNode, 'name')))
        .where((String name) => name.isNotEmpty)
        .toList();
    final DateTime? published = DateTime.tryParse(_text(entry, 'published'));
    final DateTime? updated = DateTime.tryParse(_text(entry, 'updated'));
    final String comments = _normalize(_textArxiv(entry, 'comment'));
    final List<String>? affiliations = _extractAffiliations(entry, summary);
    final String? acceptance = _extractAcceptance(summary);

    return Paper(
      id: id,
      title: title,
      abstractText: summary,
      authors: authors,
      url: id,
      publishedDate: published,
      updatedDate: updated,
      comments: comments.isEmpty ? null : comments,
      affiliations: affiliations,
      acceptanceStatus: acceptance,
    );
  }

  String _text(XmlElement node, String tag) {
    return node.findElements(tag).isEmpty ? '' : node.findElements(tag).first.innerText;
  }

  String _textArxiv(XmlElement node, String localTag) {
    for (final XmlElement child in node.descendants.whereType<XmlElement>()) {
      if (child.name.local == localTag && child.name.prefix == 'arxiv') {
        return child.innerText;
      }
    }
    return '';
  }

  String _normalize(String value) {
    return value.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  List<String>? _extractAffiliations(XmlElement entry, String summary) {
    final List<String> fromAuthor = entry
        .findElements('author')
        .expand((XmlElement authorNode) => authorNode.children.whereType<XmlElement>())
        .where((XmlElement e) => e.name.local.toLowerCase().contains('affiliation'))
        .map((XmlElement e) => _normalize(e.innerText))
        .where((String v) => v.isNotEmpty)
        .toSet()
        .toList();
    if (fromAuthor.isNotEmpty) {
      return fromAuthor;
    }

    final RegExp affReg = RegExp(
      r'(University|Institute|Laboratory|Lab|College|School|Research Center|Academy)[^.;,\n]*',
      caseSensitive: false,
    );
    final Iterable<String> guessed = affReg
        .allMatches(summary)
        .map((Match m) => _normalize(m.group(0) ?? ''))
        .where((String text) => text.length > 6)
        .toSet();
    if (guessed.isEmpty) {
      return null;
    }
    return guessed.take(3).toList();
  }

  String? _extractAcceptance(String summary) {
    final RegExp acceptReg = RegExp(
      r'(accepted\s+to\s+[A-Za-z0-9\-\s]+|under review|camera ready)',
      caseSensitive: false,
    );
    final Match? m = acceptReg.firstMatch(summary);
    if (m == null) {
      return null;
    }
    return _normalize(m.group(0) ?? '');
  }
}

class PaperReaderPage extends StatefulWidget {
  const PaperReaderPage({super.key});

  @override
  State<PaperReaderPage> createState() => _PaperReaderPageState();
}

class _PaperReaderPageState extends State<PaperReaderPage> {
  static const String _cacheKeyPapers = 'cached_papers';
  static const String _cacheKeyDate = 'cache_day';

  final ArxivService _service = ArxivService();
  final TextEditingController _searchController = TextEditingController();
  final PageController _pageController = PageController();

  List<Paper> _papers = <Paper>[];
  bool _isLoading = true;
  String? _error;
  final SortMode _sortMode = SortMode.latest;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _loadOrRefreshPapers(forceRefresh: false);
  }

  Future<void> _loadOrRefreshPapers({required bool forceRefresh}) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String today = DateTime.now().toIso8601String().split('T').first;
      final String? cachedDay = prefs.getString(_cacheKeyDate);
      final String? cachedPapers = prefs.getString(_cacheKeyPapers);
      final bool shouldUseCache =
          !forceRefresh && cachedDay == today && cachedPapers != null && cachedPapers.isNotEmpty;

      if (shouldUseCache) {
        final List<dynamic> raw = jsonDecode(cachedPapers) as List<dynamic>;
        final List<Paper> papers = raw
            .map((dynamic e) => Paper.fromJson(e as Map<String, dynamic>))
            .toList();
        setState(() {
          _papers = papers;
          _currentIndex = 0;
          _isLoading = false;
        });
        return;
      }

      final List<Paper> fresh = await _service.fetchCvprPapers(
        keyword: _searchController.text,
        sortMode: _sortMode,
      );
      await prefs.setString(
        _cacheKeyPapers,
        jsonEncode(fresh.map((Paper p) => p.toJson()).toList()),
      );
      await prefs.setString(_cacheKeyDate, today);

      setState(() {
        _papers = fresh;
        _currentIndex = 0;
        _isLoading = false;
      });
    } catch (e) {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? cachedPapers = prefs.getString(_cacheKeyPapers);
      if (cachedPapers != null && cachedPapers.isNotEmpty) {
        final List<dynamic> raw = jsonDecode(cachedPapers) as List<dynamic>;
        final List<Paper> cached = raw
            .map((dynamic item) => Paper.fromJson(item as Map<String, dynamic>))
            .toList();
        setState(() {
          _papers = cached;
          _currentIndex = 0;
          _error = 'Rate limited by arXiv (429). Showing cached papers.';
          _isLoading = false;
        });
        return;
      }
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _runSearch() async {
    await _loadOrRefreshPapers(forceRefresh: true);
  }

  Future<void> _openArxiv(Paper paper) async {
    final Uri uri = Uri.parse(paper.url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open arXiv link.')),
      );
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: <Widget>[
          const SizedBox(height: 16),
          _buildSearchBar(),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: 'Search cs.CV papers, e.g. diffusion, segmentation',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              ),
              onSubmitted: (_) => _runSearch(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _runSearch,
            child: const Text('Search'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Load failed: $_error',
            style: const TextStyle(color: Colors.redAccent),
          ),
        ),
      );
    }
    if (_papers.isEmpty) {
      return const Center(child: Text('No matching papers found.'));
    }

    return Column(
      children: <Widget>[
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            itemCount: _papers.length,
            onPageChanged: (int index) {
              setState(() {
                _currentIndex = index;
              });
            },
            itemBuilder: (BuildContext context, int index) {
              final Paper paper = _papers[index];
              return _PaperCard(
                paper: paper,
                onOpenLink: () => _openArxiv(paper),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 6, 0, 12),
          child: Text('Paper ${_currentIndex + 1} / ${_papers.length}'),
        ),
      ],
    );
  }
}

class _PaperCard extends StatelessWidget {
  const _PaperCard({
    required this.paper,
    required this.onOpenLink,
  });

  final Paper paper;
  final VoidCallback onOpenLink;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Card(
        elevation: 2,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: InkWell(
                      onTap: onOpenLink,
                      child: Text(
                        paper.title,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              color: const Color(0xFF0B7285),
                              decoration: TextDecoration.underline,
                            ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy title',
                    icon: const Icon(Icons.copy, size: 18),
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    padding: EdgeInsets.zero,
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: paper.title));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Title copied')),
                        );
                      }
                    },
                  ),
                ],
              ),
              if (paper.comments != null && paper.comments!.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Text('Comments: ${paper.comments}'),
              ],
              const SizedBox(height: 8),
              Text(
                'Authors: ${paper.authors.join(', ')}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (paper.acceptanceStatus != null && paper.acceptanceStatus!.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Text('Acceptance: ${paper.acceptanceStatus}'),
              ],
              const SizedBox(height: 12),
              Text(
                paper.abstractText,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.55),
                textAlign: TextAlign.justify,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
