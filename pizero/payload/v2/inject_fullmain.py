#!/usr/bin/env python3
# Inject an "Owner Tools" button into AppEngineerMode_FullMain.qml so the owner can browse
# to the OwnerTools page from the Full Engineering Mode menu. The button uses the literal-path
# popup (Global.popupQmlOpen) so NO native name-map entry / recompile is needed.
#
#   inject_fullmain.py <FullMain.qml in> <FullMain.qml out>
#
# Anchor: insert our MMainButton block immediately AFTER the Software button's closing brace
# (the Software button is the first MMainButton; we clone its structure). Position x/y is a
# best-effort free slot (bottom row) and MUST be visually verified on the HU.
import re, sys

OWNER_BTN = '''
        MComp.MMainButton{
            id:fullmainButtonOwnerTools
            x:1000; y:380   // row 2, slot 5 — the only free cell; slot 4 (770,380) is OEM mainButtonVariant
            focus:false
            bgImage: ImageConst.imgFolderGeneral +"ico_engineering_config_n.png"
            bgImagePress: ImageConst.imgFolderGeneral +"ico_engineering_config_p.png"
            bgImageFocus: ImageConst.imgFolderGeneral +"ico_engineering_config_f.png"
            firstText:"Owner Tools"
            onClickOrKeySelected: {
                fullmainButtonOwnerTools.forceActiveFocus()
                fullmainButtonOwnerTools.focus = true
                Global.popupQmlOpen("/app/share/AppEngineerMode/qml/owner/OwnerTools.qml", "")
            }
        }
'''

def main():
    src, dst = sys.argv[1], sys.argv[2]
    s = open(src, encoding="utf-8", errors="surrogateescape").read()
    if "fullmainButtonOwnerTools" in s:
        open(dst, "w", encoding="utf-8", errors="surrogateescape").write(s)
        print("already injected; copied unchanged"); return 0
    # find the Software button block, insert our block right after its closing brace
    i = s.find("id:fullmainButtonSoftware")
    if i < 0:
        sys.exit("anchor id:fullmainButtonSoftware not found")
    # walk to the opening brace of that MMainButton (search backwards for 'MMainButton{')
    start = s.rfind("MComp.MMainButton{", 0, i)
    if start < 0:
        sys.exit("MMainButton{ open not found before Software id")
    # brace-match from the opening '{'
    brace = s.find("{", start)
    depth, j = 0, brace
    while j < len(s):
        if s[j] == "{": depth += 1
        elif s[j] == "}":
            depth -= 1
            if depth == 0: break
        j += 1
    if depth != 0:
        sys.exit("could not brace-match Software button block")
    out = s[:j+1] + "\n" + OWNER_BTN + s[j+1:]
    open(dst, "w", encoding="utf-8", errors="surrogateescape").write(out)
    print(f"injected Owner Tools button after Software block (at offset {j+1})")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
