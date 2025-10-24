import 'package:flutter/material.dart';

class WindowsMenuBar extends StatefulWidget {
  final List<MenuTab> tabs;
  final Function(String tabName, String itemName)? onMenuItemSelected;

  const WindowsMenuBar({
    super.key,
    required this.tabs,
    this.onMenuItemSelected,
  });

  @override
  State<WindowsMenuBar> createState() => _WindowsMenuBarState();
}

class _WindowsMenuBarState extends State<WindowsMenuBar> {
  String? _activeTab;
  String? _hoveredTab;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 24,
      color: const Color(0xFFF0F0F0),
      child: Row(
        children: widget.tabs.map((tab) => _buildMenuTab(tab)).toList(),
      ),
    );
  }

  Widget _buildMenuTab(MenuTab tab) {
    final isActive = _activeTab == tab.name;
    final isHovered = _hoveredTab == tab.name;

    return GestureDetector(
      onTapDown: (_) {
        _showMenuDialog(tab);
      },
      child: MouseRegion(
        onEnter: (_) {
          setState(() {
            _hoveredTab = tab.name;
          });
        },
        onExit: (_) {
          setState(() {
            _hoveredTab = null;
          });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: isActive || isHovered 
                ? const Color(0xFFE1E1E1) 
                : Colors.transparent,
            border: isActive 
                ? const Border(
                    bottom: BorderSide(color: Color(0xFF0078D4), width: 2),
                  )
                : null,
          ),
          child: Text(
            tab.name,
            style: TextStyle(
              fontSize: 12,
              color: isActive ? const Color(0xFF0078D4) : Colors.black87,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }

  void _showMenuDialog(MenuTab tab) {
    showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(0, 24, 0, 0),
      items: tab.items.map((item) {
        if (item.name == '-') {
          return const PopupMenuItem<String>(
            enabled: false,
            child: Divider(height: 1),
          );
        }
        return PopupMenuItem<String>(
          value: item.name,
          child: Row(
            children: [
              if (item.icon != null) ...[
                Icon(
                  item.icon,
                  size: 16,
                  color: item.enabled ? Colors.black87 : Colors.grey,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  item.name,
                  style: TextStyle(
                    fontSize: 12,
                    color: item.enabled ? Colors.black87 : Colors.grey,
                  ),
                ),
              ),
              if (item.shortcut != null)
                Text(
                  item.shortcut!,
                  style: TextStyle(
                    fontSize: 10,
                    color: item.enabled ? Colors.grey[600] : Colors.grey,
                  ),
                ),
            ],
          ),
        );
      }).toList(),
    ).then((selectedItem) {
      if (selectedItem != null) {
        widget.onMenuItemSelected?.call(tab.name, selectedItem);
      }
      setState(() {
        _activeTab = null;
      });
    });
  }
}

class MenuTab {
  final String name;
  final List<MenuItem> items;

  const MenuTab({
    required this.name,
    required this.items,
  });
}

class MenuItem {
  final String name;
  final IconData? icon;
  final String? shortcut;
  final bool enabled;
  final VoidCallback? onTap;

  const MenuItem({
    required this.name,
    this.icon,
    this.shortcut,
    this.enabled = true,
    this.onTap,
  });
}