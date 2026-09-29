import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'database_helper.dart';
import 'all_schedules_screen.dart';
import 'growth_stages.dart'; // ✅ NEW

class AddPlantScreen extends StatefulWidget {
  const AddPlantScreen({super.key});

  @override
  AddPlantScreenState createState() => AddPlantScreenState();
}

class AddPlantScreenState extends State<AddPlantScreen> {
  final nameController = TextEditingController();
  final typeController = TextEditingController();
  final descController = TextEditingController();

  File? selectedImage;
  final ImagePicker _picker = ImagePicker();

  // ✅ NEW: tracks the chosen growth stage (null = no stage set)
  String? _selectedStage;

  bool isSaving = false;

  // =========================
  // 📸 PICK IMAGE
  // =========================
  Future<void> pickImage() async {
    final XFile? image = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );

    if (image == null) return;

    setState(() {
      selectedImage = File(image.path);
    });
  }

  // =========================
  // 💾 SAVE PLANT
  // =========================
  Future<void> savePlant() async {
    final name = nameController.text.trim();
    final type = typeController.text.trim();
    final desc = descController.text.trim();

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Plant name is required")),
      );
      return;
    }

    setState(() => isSaving = true);

    try {
      await DatabaseHelper.instance.insertPlant({
        'name':         name,
        'type':         type,
        'description':  desc,
        'imagePath':    selectedImage?.path,
        // ✅ Only include growth_stage when one has been selected
        if (_selectedStage != null) 'growth_stage': _selectedStage,
      });

      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error saving plant: $e")),
      );
    } finally {
      if (mounted) {
        setState(() => isSaving = false);
      }
    }
  }

  // =========================
  // UI
  // =========================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Add Plant"),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_today),
            tooltip: "View All Schedules",
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const AllSchedulesScreen(),
                ),
              );
            },
          ),
        ],
      ),

      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: "Plant Name"),
            ),

            const SizedBox(height: 10),

            TextField(
              controller: typeController,
              decoration: const InputDecoration(labelText: "Plant Type"),
            ),

            const SizedBox(height: 10),

            TextField(
              controller: descController,
              decoration: const InputDecoration(labelText: "Description"),
              maxLines: 3,
            ),

            const SizedBox(height: 24),

            // =========================
            // 🌱 GROWTH STAGE SELECTOR
            // =========================
            const Text(
              "Growth Stage",
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 8),
            GrowthStageSelector(
              selectedStage: _selectedStage,
              onStageSelected: (stage) {
                setState(() => _selectedStage = stage);
              },
              allowClear: true,
            ),

            const SizedBox(height: 20),

            // =========================
            // 📸 IMAGE PREVIEW
            // =========================
            Container(
              height: 180,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(12),
                image: selectedImage != null
                    ? DecorationImage(
                        image: FileImage(selectedImage!),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: selectedImage == null
                  ? const Center(child: Text("No Image Selected"))
                  : null,
            ),

            const SizedBox(height: 12),

            ElevatedButton.icon(
              onPressed: pickImage,
              icon: const Icon(Icons.photo_library),
              label: const Text("Add Plant Image"),
            ),

            const SizedBox(height: 20),

            // =========================
            // 💾 SAVE BUTTON
            // =========================
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: isSaving ? null : savePlant,
                child: isSaving
                    ? const CircularProgressIndicator()
                    : const Text("Save Plant"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}