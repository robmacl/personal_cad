# Lists the documents open in the running SolidWorks and closes the light box ones (files under this
# project's directory). The generator opens a part every run and never closes it, so they pile up.
#   powershell -ExecutionPolicy Bypass -File lightbox_close.ps1          list only
#   powershell -ExecutionPolicy Bypass -File lightbox_close.ps1 -Close   close this project's documents
# A project document with unsaved changes is saved first. Documents outside this project are never touched.
param([switch]$Close)
$api = "C:\Program Files\SOLIDWORKS Corp\SOLIDWORKS\api\redist"
$refs = @("$api\SolidWorks.Interop.sldworks.dll", "$api\SolidWorks.Interop.swconst.dll")
$code = @'
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
using SolidWorks.Interop.sldworks; using SolidWorks.Interop.swconst;
public static class Closer {
  public static string Run(string root, bool close) {
    SldWorks sw;
    try { sw = (SldWorks)Marshal.GetActiveObject("SldWorks.Application"); } catch (Exception) { return "SolidWorks is not running."; }
    StringBuilder log = new StringBuilder();
    object[] docs = (object[])sw.GetDocuments();
    if (docs == null) return "no documents open";
    List<ModelDoc2> mine = new List<ModelDoc2>();
    foreach (object o in docs) {
      ModelDoc2 d = (ModelDoc2)o;
      string path = d.GetPathName();
      bool ours = path != "" && path.StartsWith(root, StringComparison.OrdinalIgnoreCase);
      log.AppendLine(String.Format("  {0,-8} {1,-7} {2,-9} {3}", ours ? "project" : "OTHER", d.GetType() == 2 ? "asm" : d.GetType() == 1 ? "part" : "drawing", d.GetSaveFlag() ? "UNSAVED" : "saved", path == "" ? d.GetTitle() + " (never saved)" : path));
      if (ours) mine.Add(d);
    }
    if (!close) return log.ToString();
    // assemblies first, so their parts are no longer held open by them
    mine.Sort(delegate(ModelDoc2 a, ModelDoc2 b) { return b.GetType().CompareTo(a.GetType()); });
    int n = 0;
    foreach (ModelDoc2 d in mine) {
      if (d.GetSaveFlag()) {
        // the generator saves every part when it finishes; what is left is rebuild flags from the assembly and the exports. Save, so nothing can be lost.
        int e = 0, w = 0;
        if (!d.Save3((int)swSaveAsOptions_e.swSaveAsOptions_Silent, ref e, ref w)) { log.AppendLine("  left open, could not save: " + d.GetTitle() + " err " + e); continue; }
      }
      string t = d.GetTitle();
      sw.CloseDoc(t); n++;
    }
    object[] left = (object[])sw.GetDocuments();
    log.AppendLine("closed " + n + "; documents still open: " + (left == null ? 0 : left.Length));
    return log.ToString();
  }
}
'@
Add-Type -TypeDefinition $code -ReferencedAssemblies $refs
foreach ($r in $refs) { [Reflection.Assembly]::LoadFrom($r) | Out-Null }
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
[Closer]::Run($root, [bool]$Close)
