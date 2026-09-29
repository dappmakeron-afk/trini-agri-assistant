import 'dart:io';
import 'package:flutter/material.dart';
import 'database_helper.dart';

class PlantGalleryScreen extends StatefulWidget {
  final Map<String, dynamic> plant;

  const PlantGalleryScreen({super.key, required this.plant});

  @override
  State<PlantGalleryScreen> createState() => _PlantGalleryScreenState();
}

class _PlantGalleryScreenState extends State<PlantGalleryScreen> {
  List<String> _images = [];

  // FIX: use the DB helper method instead of raw DB access so any schema
  // changes only need to be handled in one place (database_helper.dart).
  Future<void> _loadImages() async {
    final rows = await DatabaseHelper.instance
        .getPlantImages(widget.plant['id'] as int);
    // FIX: mounted guard — the async gap between await and setState means
    // the widget could have been disposed before we get here.
    if (!mounted) return;
    setState(() {
      _images =
          rows.map((e) => e['imagePath'] as String).toList();
    });
  }

  @override
  void initState() {
    super.initState();
    _loadImages();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("${widget.plant['name']} Gallery"),
      ),
      body: _images.isEmpty
          ? const Center(child: Text("No images yet"))
          : GridView.builder(
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
              ),
              itemCount: _images.length,
              itemBuilder: (context, i) {
                return Padding(
                  padding: const EdgeInsets.all(6),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.file(
                      File(_images[i]),
                      fit: BoxFit.cover,
                      // Graceful fallback if the file has been deleted
                      // from disk since it was saved (e.g. cache clear).
                      errorBuilder: (_, __, ___) => Container(
                        color: Colors.grey.shade200,
                        child: const Icon(Icons.broken_image,
                            color: Colors.grey),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}