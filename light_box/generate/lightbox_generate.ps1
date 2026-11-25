# Generates the light box v2 printed parts in a running SolidWorks session.
#
#   powershell -ExecutionPolicy Bypass -File lightbox_generate.ps1 [-What gauge|blockA|blockB|bracketA|bracketB|footA|footB|spacer|handleA|handleB|bar|saddle|chanMock|mock|housing|diffuser|chanSide|chanEnd|assembly] [-ImgDir <dir>]
#   powershell -ExecutionPolicy Bypass -File lightbox_generate.ps1 -What stl -StlTag <tag> [-StlParts a,b,...]
#
# The second form writes fine STL print files to ../stl/lb_<part>_<tag>.STL.
# Every dimension comes from lightbox_params.json (millimetres). Edit it and run again: parts are
# stripped and rebuilt in place. Sketches carry no dimensions; the JSON and this script are the design.
# See ../light_box_notes.txt. Helpers copied from mindfulnest-hardware/cad/Squeeze/generate.
#
# Frame parts are modelled in the corner-local frame described in the code (not print orientation),
# so the exported meshes can be checked against the mock of the light. One part per run.
param([string]$What = "gauge", [string]$ImgDir = "", [string]$StlTag = "print", [string]$StlParts = "corner_block_A,corner_block_B,bracket_A,bracket_B")

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$outDir = Split-Path -Parent $here
$redist = "C:\Program Files\SOLIDWORKS Corp\SOLIDWORKS\api\redist"
$refs = @("$redist\SolidWorks.Interop.sldworks.dll", "$redist\SolidWorks.Interop.swconst.dll")

$code = @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using SolidWorks.Interop.sldworks;
using SolidWorks.Interop.swconst;

public static class Gen {
  static SldWorks sw; static ModelDoc2 doc; static StringBuilder log = new StringBuilder();
  static Dictionary<string, double> P; static List<string> PKeys;
  static Dictionary<string, string> planes = new Dictionary<string, string>();
  const double MM = 0.001;
  static double p(string k) { if (!P.ContainsKey(k)) throw new Exception("missing parameter " + k); return P[k]; }


  // ---------------------------------------------------------------- sketch helpers (model mm in)
  static double[] S(double[] m) {
    Sketch sk = (Sketch)doc.SketchManager.ActiveSketch;
    MathUtility mu = (MathUtility)sw.GetMathUtility();
    MathPoint q = (MathPoint)mu.CreatePoint(new double[] { m[0] * MM, m[1] * MM, m[2] * MM });
    q = (MathPoint)q.MultiplyTransform(sk.ModelToSketchTransform);
    return (double[])q.ArrayData;
  }
  static double[] V(double x, double y, double z) { return new double[] { x, y, z }; }
  static void Open(string plane) {
    doc.ClearSelection2(true);
    if (!doc.Extension.SelectByID2(plane, "PLANE", 0, 0, 0, false, 0, null, 0)) log.AppendLine("  !! could not select plane " + plane);
    doc.SketchManager.InsertSketch(true);
    doc.SketchManager.AddToDB = true;
  }
  static Feature Close(string name) {
    doc.SketchManager.AddToDB = false;
    doc.SketchManager.InsertSketch(true);
    Feature f = (Feature)doc.FeatureByPositionReverse(0);
    f.Name = name;
    return f;
  }
  static SketchSegment Ln(double[] a, double[] b) {
    double d = Math.Sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[2]) * (a[2] - b[2]));
    if (d < 1e-6) return null;
    double[] s = S(a), e = S(b);
    return (SketchSegment)doc.SketchManager.CreateLine(s[0], s[1], s[2], e[0], e[1], e[2]);
  }
  static int Turn(double[] s, double[] m, double[] e) { return ((m[0] - s[0]) * (e[1] - m[1]) - (m[1] - s[1]) * (e[0] - m[0])) > 0 ? 1 : -1; }
  static void EllArcM(double[] c, double[] maj, double[] min, double[] s, double[] m, double[] e) {
    double[] C = S(c), A = S(maj), B = S(min), a = S(s), M = S(m), b = S(e);
    object o = doc.SketchManager.CreateEllipticalArc(C[0], C[1], C[2], A[0], A[1], A[2], B[0], B[1], B[2], a[0], a[1], a[2], b[0], b[1], b[2], (short)Turn(a, M, b));
    if (o == null) log.AppendLine("  !! elliptical arc failed");
  }
  static void CircArcM(double[] c, double[] s, double[] m, double[] e) {
    double[] C = S(c), a = S(s), M = S(m), b = S(e);
    object o = doc.SketchManager.CreateArc(C[0], C[1], C[2], a[0], a[1], a[2], b[0], b[1], b[2], (short)Turn(a, M, b));
    if (o == null) log.AppendLine("  !! arc failed");
  }
  static void Circle(double[] c, double dia) {
    double[] C = S(c);
    if (doc.SketchManager.CreateCircleByRadius(C[0], C[1], C[2], dia / 2 * MM) == null) log.AppendLine("  !! circle failed");
  }
  static void Name(Feature f, string n) { if (f != null) f.Name = n; else log.AppendLine("  !! feature failed: " + n); }

  // ---------------------------------------------------------------- features
  static Feature ExtrudeMid(Feature sketch, double depth, bool cut) {
    doc.ClearSelection2(true);
    sketch.Select2(false, 0);
    if (cut) return (Feature)doc.FeatureManager.FeatureCut4(true, false, false, (int)swEndConditions_e.swEndCondMidPlane, 0, depth * MM, 0,
      false, false, false, false, 0, 0, false, false, false, false, false, true, true, true, true, false, (int)swStartConditions_e.swStartSketchPlane, 0, false, false);
    return (Feature)doc.FeatureManager.FeatureExtrusion3(true, false, false, (int)swEndConditions_e.swEndCondMidPlane, 0, depth * MM, 0,
      false, false, false, false, 0, 0, false, false, false, false, true, true, true, (int)swStartConditions_e.swStartSketchPlane, 0, false);
  }
  static Feature CutThrough(Feature sketch) {
    doc.ClearSelection2(true);
    sketch.Select2(false, 0);
    return (Feature)doc.FeatureManager.FeatureCut4(false, false, false, (int)swEndConditions_e.swEndCondThroughAll, (int)swEndConditions_e.swEndCondThroughAll, 0.01, 0.01,
      false, false, false, false, 0, 0, false, false, false, false, false, true, true, true, true, false, (int)swStartConditions_e.swStartSketchPlane, 0, false, false);
  }
  static Feature Revolve(Feature sketch, SketchSegment axis, bool half, bool cut) {
    doc.ClearSelection2(true);
    sketch.Select2(false, 0);
    SelectData sd = (SelectData)((SelectionMgr)doc.SelectionManager).CreateSelectData();
    sd.Mark = 16;
    axis.Select4(true, sd);
    return (Feature)doc.FeatureManager.FeatureRevolve2(true, true, false, cut, false, false,
      half ? (int)swEndConditions_e.swEndCondMidPlane : (int)swEndConditions_e.swEndCondBlind, 0, half ? Math.PI : 2 * Math.PI, 0,
      false, false, 0, 0, 0, 0, 0, true, true, true);
  }

  // offset reference planes, cached. idx 0: parallel to Right (x = v); 1: parallel to Top (y = v); 2: parallel to Front (z = v)
  static string PlaneAt(int idx, double v) {
    string[] bases = { "Right Plane", "Top Plane", "Front Plane" };
    if (Math.Abs(v) < 1e-6) return bases[idx];
    string key = "P" + "XYZ"[idx] + " " + v.ToString("F3");
    if (planes.ContainsKey(key)) return planes[key];
    for (int attempt = 0; attempt < 2; attempt++) {
      doc.ClearSelection2(true);
      doc.Extension.SelectByID2(bases[idx], "PLANE", 0, 0, 0, false, 0, null, 0);
      int opt = (int)swRefPlaneReferenceConstraints_e.swRefPlaneReferenceConstraint_Distance;
      bool flip = (v < 0) ^ (attempt == 1);
      if (flip) opt |= (int)swRefPlaneReferenceConstraints_e.swRefPlaneReferenceConstraint_OptionFlip;
      Feature f = (Feature)doc.FeatureManager.InsertRefPlane(opt, Math.Abs(v) * MM, 0, 0, 0, 0);
      if (f == null) { log.AppendLine("  !! plane failed " + key); continue; }
      RefPlane rp = (RefPlane)f.GetSpecificFeature2();
      double[] t = (double[])rp.Transform.ArrayData;
      double pos = t[9 + idx] / MM;
      if (Math.Abs(pos - v) < 1e-4) { f.Name = key; planes[key] = key; doc.ClearSelection2(true); return key; }
      doc.ClearSelection2(true); f.Select2(false, 0); doc.Extension.DeleteSelection2(0);
    }
    throw new Exception("could not place plane " + key);
  }

  // vertical cylinders: each entry {x, y, dia}; from z1 to z2
  static Feature Cyls(double[][] xyd, double z1, double z2, bool cut, string name) {
    double zm = (z1 + z2) / 2;
    Open(PlaneAt(2, zm));
    foreach (double[] c in xyd) Circle(V(c[0], c[1], zm), c[2]);
    Feature f = ExtrudeMid(Close(name + " sketch"), z2 - z1, cut);
    Name(f, name);
    return f;
  }
  // vertical prism from a closed polygon {x, y}; from z1 to z2
  static Feature Prism(double[][] xy, double z1, double z2, bool cut, string name) {
    double zm = (z1 + z2) / 2;
    Open(PlaneAt(2, zm));
    for (int i = 0; i < xy.Length; i++) { double[] a = xy[i], b = xy[(i + 1) % xy.Length]; Ln(V(a[0], a[1], zm), V(b[0], b[1], zm)); }
    Feature f = ExtrudeMid(Close(name + " sketch"), z2 - z1, cut);
    Name(f, name);
    return f;
  }

  // ---------------------------------------------------------------- document handling
  static bool OpenOrNew(string path) {
    planes.Clear();
    int e = 0, w = 0;
    if (System.IO.File.Exists(path)) {
      doc = (ModelDoc2)sw.OpenDoc6(path, (int)swDocumentTypes_e.swDocPART, (int)swOpenDocOptions_e.swOpenDocOptions_Silent, "", ref e, ref w);
      if (doc == null) { log.AppendLine("!! could not open " + path + " err " + e); return false; }
      doc = (ModelDoc2)sw.ActivateDoc3(doc.GetTitle(), false, (int)swRebuildOnActivation_e.swDontRebuildActiveDoc, ref e);
      List<Feature> kill = new List<Feature>();
      bool after = false;
      Feature f = (Feature)doc.FirstFeature();
      while (f != null) { if (after) kill.Add(f); if (f.GetTypeName2() == "OriginProfileFeature") after = true; f = (Feature)f.GetNextFeature(); }
      if (kill.Count > 0) {
        doc.ClearSelection2(true);
        foreach (Feature k in kill) k.Select2(true, 0);
        doc.Extension.DeleteSelection2((int)swDeleteSelectionOptions_e.swDelete_Absorbed | (int)swDeleteSelectionOptions_e.swDelete_Children);
      }
      object[] bodies = (object[])((PartDoc)doc).GetBodies2((int)swBodyType_e.swSolidBody, true);
      if (bodies != null && bodies.Length > 0) { log.AppendLine("!! could not clear " + path); return false; }
    } else {
      string tpl = sw.GetUserPreferenceStringValue((int)swUserPreferenceStringValue_e.swDefaultTemplatePart);
      doc = (ModelDoc2)sw.NewDocument(tpl, 0, 0, 0);
      if (doc == null) { log.AppendLine("!! NewDocument failed"); return false; }
    }
    return true;
  }
  static double finTransp = 0;
  static bool saddleViews = false;
  static void Finish(string path, string tag, double r, double g, double b, string imgDir, string view, int viewId) {
    doc.ClearSelection2(true);
    EquationMgr eq = (EquationMgr)doc.GetEquationMgr();
    foreach (string k in PKeys) eq.Add2(-1, "\"" + k + "\" = " + P[k].ToString("0.####") + "mm", false);
    // hide the construction planes and every sketch
    Feature pf = (Feature)doc.FirstFeature();
    while (pf != null) {
      if (pf.GetTypeName2() == "RefPlane" && planes.ContainsKey(pf.Name)) { doc.ClearSelection2(true); pf.Select2(false, 0); doc.BlankRefGeom(); }
      if (pf.GetTypeName2() == "ProfileFeature") { doc.ClearSelection2(true); pf.Select2(false, 0); doc.BlankSketch(); }
      Feature sf = (Feature)pf.GetFirstSubFeature();
      while (sf != null) { if (sf.GetTypeName2() == "ProfileFeature") { doc.ClearSelection2(true); sf.Select2(false, 0); doc.BlankSketch(); } sf = (Feature)sf.GetNextSubFeature(); }
      pf = (Feature)pf.GetNextFeature();
    }
    doc.ClearSelection2(true);
    doc.ForceRebuild3(false);
    doc.MaterialPropertyValues = new double[] { r, g, b, 1.0, 1.0, 0.2, 0.3, finTransp, 0.0 };
    // report
    object[] bodies = (object[])((PartDoc)doc).GetBodies2((int)swBodyType_e.swSolidBody, true);
    if (bodies == null) { log.AppendLine(tag + ": !! no body"); return; }
    double[] lo = { 1e9, 1e9, 1e9 }, hi = { -1e9, -1e9, -1e9 };
    foreach (object bo in bodies) { double[] bb = (double[])((Body2)bo).GetBodyBox(); for (int i = 0; i < 3; i++) { lo[i] = Math.Min(lo[i], bb[i]); hi[i] = Math.Max(hi[i], bb[i + 3]); } }
    MassProperty mp = (MassProperty)doc.Extension.CreateMassProperty();
    log.AppendLine(String.Format("{0}: bodies {1}  x {2:F1}..{5:F1}  y {3:F1}..{6:F1}  z {4:F1}..{7:F1}  volume {8:F1} cm3", tag, bodies.Length, lo[0] * 1000, lo[1] * 1000, lo[2] * 1000, hi[0] * 1000, hi[1] * 1000, hi[2] * 1000, mp.Volume * 1e6));
    int bad = 0;
    Feature f = (Feature)doc.FirstFeature();
    while (f != null) { bool warn; int ec = f.GetErrorCode2(out warn); if (ec != 0) { bad++; log.AppendLine("  !! " + (warn ? "warning" : "error") + " " + ec + " in feature " + f.Name); } f = (Feature)f.GetNextFeature(); }
    int e = 0, w = 0;
    bool ok = System.IO.File.Exists(path) && String.Equals(doc.GetPathName(), path, StringComparison.OrdinalIgnoreCase)
      ? doc.Save3((int)swSaveAsOptions_e.swSaveAsOptions_Silent, ref e, ref w)
      : doc.Extension.SaveAs(path, 0, (int)swSaveAsOptions_e.swSaveAsOptions_Silent, null, ref e, ref w);
    log.AppendLine(tag + ": saved " + ok + (e != 0 ? " err " + e : "") + (bad == 0 ? ", no feature errors" : ""));
    if (imgDir != "") {
      doc.ShowNamedView2(view, viewId); doc.ViewZoomtofit2(); doc.GraphicsRedraw2();
      doc.Extension.SaveAs(imgDir + "\\" + tag + ".jpg", 0, (int)swSaveAsOptions_e.swSaveAsOptions_Silent | (int)swSaveAsOptions_e.swSaveAsOptions_Copy, null, ref e, ref w);
      bool old = sw.GetUserPreferenceToggle((int)swUserPreferenceToggle_e.swSTLDontTranslateToPositive);
      sw.SetUserPreferenceToggle((int)swUserPreferenceToggle_e.swSTLDontTranslateToPositive, true);
      doc.Extension.SaveAs(imgDir + "\\" + tag + ".STL", 0, (int)swSaveAsOptions_e.swSaveAsOptions_Silent | (int)swSaveAsOptions_e.swSaveAsOptions_Copy, null, ref e, ref w);
      sw.SetUserPreferenceToggle((int)swUserPreferenceToggle_e.swSTLDontTranslateToPositive, old);
      if (footMode) {
        // the side of the foot that meets the lamp: square on, and from an angle
        doc.ShowNamedView2("*Bottom", 6); doc.ViewZoomtofit2(); doc.GraphicsRedraw2();
        doc.Extension.SaveAs(imgDir + "\\" + tag + "_lampside.jpg", 0, (int)swSaveAsOptions_e.swSaveAsOptions_Silent | (int)swSaveAsOptions_e.swSaveAsOptions_Copy, null, ref e, ref w);
        ((ModelView)doc.ActiveView).RotateAboutCenter(-0.85, 0.55); doc.ViewZoomtofit2(); doc.GraphicsRedraw2();
        doc.Extension.SaveAs(imgDir + "\\" + tag + "_lampside_oblique.jpg", 0, (int)swSaveAsOptions_e.swSaveAsOptions_Silent | (int)swSaveAsOptions_e.swSaveAsOptions_Copy, null, ref e, ref w);
      }
      if (saddleViews) {
        string[] nm = { "_top", "_under", "_end", "_side" }; string[] vw = { "*Front", "*Back", "*Right", "*Top" }; int[] id = { 1, 2, 4, 5 };
        for (int i = 0; i < nm.Length; i++) {
          doc.ShowNamedView2(vw[i], id[i]); doc.ViewZoomtofit2(); doc.GraphicsRedraw2();
          doc.Extension.SaveAs(imgDir + "\\" + tag + nm[i] + ".jpg", 0, (int)swSaveAsOptions_e.swSaveAsOptions_Silent | (int)swSaveAsOptions_e.swSaveAsOptions_Copy, null, ref e, ref w);
        }
        double[][] rot = { new double[] { -1.1, 0.5 }, new double[] { 1.1, 0.5 }, new double[] { -1.1, -0.5 }, new double[] { 1.1, -0.5 } };
        for (int i = 0; i < rot.Length; i++) {
          doc.ShowNamedView2("*Front", 1); ((ModelView)doc.ActiveView).RotateAboutCenter(rot[i][0], rot[i][1]); doc.ViewZoomtofit2(); doc.GraphicsRedraw2();
          doc.Extension.SaveAs(imgDir + "\\" + tag + "_oblique" + (i + 1) + ".jpg", 0, (int)swSaveAsOptions_e.swSaveAsOptions_Silent | (int)swSaveAsOptions_e.swSaveAsOptions_Copy, null, ref e, ref w);
        }
      }
    }
  }

  // ================================================================ light box v2 parts
  // Corner-local frame (mm): x = 0 on the side plane of the light, +x outward; y = 0 on the end of the
  // housing, +y outward past the end; z = 0 on the front edge of the lamp, +z toward the viewer.
  // Hand "A" is built as written; hand "B" is its mirror in x (sgn = -1).
  static double sgn = 1;
  static string SEP = System.IO.Path.DirectorySeparatorChar.ToString();
  static double[][] Rect(double x1, double y1, double x2, double y2) { return new double[][] { new double[] { x1, y1 }, new double[] { x2, y1 }, new double[] { x2, y2 }, new double[] { x1, y2 } }; }
  static double[][] MirXY(double[][] a) { double[][] r = new double[a.Length][]; for (int i = 0; i < a.Length; i++) r[i] = new double[] { sgn * a[i][0], a[i][1] }; return r; }
  static Feature PZ(double[][] xy, double z1, double z2, bool cut, string name) { return Prism(MirXY(xy), z1, z2, cut, name); }
  // prism along y from a closed polygon {x, z}
  static Feature PY(double[][] xz, double y1, double y2, bool cut, string name) {
    double ym = (y1 + y2) / 2;
    Open(PlaneAt(1, ym));
    for (int i = 0; i < xz.Length; i++) { double[] a = xz[i], b = xz[(i + 1) % xz.Length]; Ln(V(sgn * a[0], ym, a[1]), V(sgn * b[0], ym, b[1])); }
    Feature f = ExtrudeMid(Close(name + " sketch"), y2 - y1, cut);
    Name(f, name);
    return f;
  }
  // prism along x from a closed polygon {y, z}
  static Feature PX(double[][] yz, double x1, double x2, bool cut, string name) {
    double xm = sgn * (x1 + x2) / 2;
    Open(PlaneAt(0, xm));
    for (int i = 0; i < yz.Length; i++) { double[] a = yz[i], b = yz[(i + 1) % yz.Length]; Ln(V(xm, a[0], a[1]), V(xm, b[0], b[1])); }
    Feature f = ExtrudeMid(Close(name + " sketch"), Math.Abs(x2 - x1), cut);
    Name(f, name);
    return f;
  }
  // cylinders along x: each entry {y, z, dia}
  static Feature CX(double[][] yzd, double x1, double x2, bool cut, string name) {
    double xm = sgn * (x1 + x2) / 2;
    Open(PlaneAt(0, xm));
    foreach (double[] c in yzd) Circle(V(xm, c[0], c[1]), c[2]);
    Feature f = ExtrudeMid(Close(name + " sketch"), Math.Abs(x2 - x1), cut);
    Name(f, name);
    return f;
  }
  // round cut about an axis along x through (yc, zc): the profile is {x, radius} points in order, closed along the axis
  static Feature RevCutX(double yc, double zc, double[][] xr, string name) {
    Open(PlaneAt(2, zc));
    int n = xr.Length;
    SketchSegment axis = Ln(V(sgn * xr[n - 1][0], yc, zc), V(sgn * xr[0][0], yc, zc));
    Ln(V(sgn * xr[0][0], yc, zc), V(sgn * xr[0][0], yc + xr[0][1], zc));
    for (int i = 0; i + 1 < n; i++) Ln(V(sgn * xr[i][0], yc + xr[i][1], zc), V(sgn * xr[i + 1][0], yc + xr[i + 1][1], zc));
    Ln(V(sgn * xr[n - 1][0], yc + xr[n - 1][1], zc), V(sgn * xr[n - 1][0], yc, zc));
    Feature f = Revolve(Close(name + " sketch"), axis, false, true);
    Name(f, name);
    return f;
  }
  // round cut about an axis lying in the plane y = yc: from (ax, az) along unit (nx, nz) for len, radius r
  static Feature RevCutY(double yc, double ax, double az, double nx, double nz, double len, double r, string name) {
    double dx = -nz, dz = nx;
    Open(PlaneAt(1, yc));
    double[] a0 = V(sgn * ax, yc, az), a1 = V(sgn * (ax + len * nx), yc, az + len * nz);
    double[] b1 = V(sgn * (ax + len * nx + r * dx), yc, az + len * nz + r * dz), b0 = V(sgn * (ax + r * dx), yc, az + r * dz);
    SketchSegment axis = Ln(a0, a1); Ln(a1, b1); Ln(b1, b0); Ln(b0, a0);
    Feature f = Revolve(Close(name + " sketch"), axis, false, true);
    Name(f, name);
    return f;
  }
  static Feature RevCutYAdd(double yc, double ax, double az, double nx, double nz, double len, double r, string name) {
    double dx = -nz, dz = nx;
    Open(PlaneAt(1, yc));
    double[] a0 = V(sgn * ax, yc, az), a1 = V(sgn * (ax + len * nx), yc, az + len * nz);
    double[] b1 = V(sgn * (ax + len * nx + r * dx), yc, az + len * nz + r * dz), b0 = V(sgn * (ax + r * dx), yc, az + r * dz);
    SketchSegment axis = Ln(a0, a1); Ln(a1, b1); Ln(b1, b0); Ln(b0, a0);
    Feature f = Revolve(Close(name + " sketch"), axis, false, false);
    Name(f, name);
    return f;
  }

  // Find an edge or face by geometry (picking by coordinates goes through the view and misses hidden ones).
  static bool Pick(double[] q, bool face, bool append, int mark, string name) {
    object[] bodies = (object[])((PartDoc)doc).GetBodies2((int)swBodyType_e.swSolidBody, true);
    double x = sgn * q[0] * MM, y = q[1] * MM, z = q[2] * MM, best = 1e9; object hit = null;
    if (bodies != null) foreach (Body2 bd in bodies) {
      object[] ents = (object[])(face ? bd.GetFaces() : bd.GetEdges());
      if (ents == null) continue;
      foreach (object o in ents) {
        double[] c = (double[])(face ? ((Face2)o).GetClosestPointOn(x, y, z) : ((Edge)o).GetClosestPointOn(x, y, z));
        if (c == null) continue;
        double dd = Math.Sqrt((c[0] - x) * (c[0] - x) + (c[1] - y) * (c[1] - y) + (c[2] - z) * (c[2] - z));
        if (dd < best) { best = dd; hit = o; }
      }
    }
    if (hit == null || best > 0.05 * MM) { log.AppendLine(String.Format("  !! {0}: no {1} at {2:F1}, {3:F1}, {4:F1} (nearest {5:F2} mm away)", name, face ? "face" : "edge", q[0], q[1], q[2], best / MM)); return false; }
    SelectData sd = (SelectData)((SelectionMgr)doc.SelectionManager).CreateSelectData();
    sd.Mark = mark;
    return ((Entity)hit).Select4(append, sd);
  }
  // fillet the edges that pass through the given model points {x, y, z} (x is mirrored for hand B). Concave or convex.
  static bool filChain = false;   // true: the fillet runs on along tangent edges
  static Feature FilC(double r, string name, params double[][] pts) { filChain = true; Feature f = Fil(r, name, pts); filChain = false; return f; }
  // 45 deg chamfer on the edges through the given points (for corners that touch the bed, where a round would overhang)
  static bool chamChain = false;
  static Feature ChamC(double w, string name, params double[][] pts) { chamChain = true; Feature f = ChamE(w, name, pts); chamChain = false; return f; }
  static Feature ChamE(double w, string name, params double[][] pts) {
    doc.ClearSelection2(true);
    int n = 0;
    foreach (double[] q in pts) if (Pick(q, false, true, 0, name)) n++;
    if (n == 0) return null;
    Feature f = (Feature)doc.FeatureManager.InsertFeatureChamfer(chamChain ? 4 : 0, 1, w * MM, Math.PI / 4, 0, 0, 0, 0);
    Name(f, name);
    return f;
  }
  static Feature Fil(double r, string name, params double[][] pts) {
    doc.ClearSelection2(true);
    int n = 0;
    foreach (double[] q in pts) if (Pick(q, false, true, 1, name)) n++;
    if (n == 0) return null;
    Feature f = (Feature)doc.FeatureManager.FeatureFillet3(filChain ? 195 : 194, r * MM, 0, 0, 0, 0, 0, null, null, null, null, null, null, null);
    Name(f, name);
    return f;
  }
  // 45 deg chamfer round the face that contains the model point (the bed face of a print)
  static Feature Cham(double w, string name, double[] q) {
    doc.ClearSelection2(true);
    if (!Pick(q, true, false, 0, name)) return null;
    Feature f = (Feature)doc.FeatureManager.InsertFeatureChamfer(4, 1, w * MM, Math.PI / 4, 0, 0, 0, 0);
    Name(f, name);
    return f;
  }

  class Lay {
    public double zf, zFront, zRearIn, zRearOut, zb, zSeat, zTop, zScrew, zLeg, zLip;
    public double webInX, webOutX, bumpX, tipX, webInY, webOutY, bumpY, tipY;
    public double xe, ys, yi, slopeAng, dX, dZ, nX, nZ, cX, cZ, jog;
  }
  static Lay L() {
    Lay a = new Lay();
    a.zf = p("gap") + p("diffT");                       // inside of the front leg of the channel = diffuser front
    a.zFront = a.zf + p("chanFloor");
    a.zRearIn = a.zf - p("chanSlotW");
    a.zRearOut = a.zRearIn - p("chanFloor");
    a.zb = a.zRearIn + p("tongueClrZ");                 // underside of block and tongues
    a.zSeat = p("gap") - p("seatClr");                  // top of tongues and body: the back of the diffuser rests here
    a.zTop = a.zFront + p("proud");
    a.zScrew = (a.zRearOut + a.zSeat) / 2;                // middle of the block body, which now runs back to the channel's rear face
    a.zLeg = a.zTop - p("legBelowFront");                // top of the bracket leg, short of the front face of the corner cap
    a.zLip = a.zf + p("lipClr");                         // underside of the lip over the front of the diffuser corner
    a.webInX = (p("diffW") + 2 * p("edgeW") - p("lightW")) / 2;
    a.webOutX = a.webInX + p("chanFloor"); a.bumpX = a.webOutX + p("proud"); a.tipX = a.webInX - p("chanSlotDepth");
    a.webInY = (p("diffL") + 2 * p("edgeL") - p("lightL")) / 2;
    a.webOutY = a.webInY + p("chanFloor"); a.bumpY = a.webOutY + p("proud"); a.tipY = a.webInY - p("chanSlotDepth");
    a.xe = a.webOutX - p("armEnd"); a.ys = a.webOutY - p("armSide");
    a.yi = -p("insFromEnd");
    double rise = p("lightWingDepth") - p("lightSideFlat"), len = p("lightSlopeLen"), run = Math.Sqrt(len * len - rise * rise);
    a.dX = -run / len; a.dZ = -rise / len;              // down the angled face, away from the side-flat bend
    a.nX = -a.dZ; a.nZ = a.dX;                          // out of the angled face
    a.slopeAng = Math.Atan2(rise, run) * 180 / Math.PI;
    a.cX = p("insUpSlope") * a.dX; a.cZ = -p("lightSideFlat") + p("insUpSlope") * a.dZ;
    a.jog = a.bumpX;                                    // the bracket leg lies on the outside face of the corner cap
    return a;
  }
  static void LayoutReport(Lay a) {
    log.AppendLine(String.Format("  layout: frame outside {0:F1} x {1:F1}; channel z {2:F2}..{3:F2}; diffuser z {4:F2}..{5:F2}",
      p("lightW") + 2 * a.webOutX, p("lightL") + 2 * a.webOutY, a.zRearOut, a.zFront, p("gap"), a.zf));
    log.AppendLine(String.Format("  frame proud of light: side {0:F2}, end {1:F2}; angled face {2:F1} deg; insert at x {3:F1}, y {4:F1}, z {5:F1}",
      a.webOutX, a.webOutY, a.slopeAng, a.cX, a.yi, a.cZ));
    log.AppendLine(String.Format("  CUT LENGTHS: side channels {0:F1} mm ({1:F3} in), end channels {2:F1} mm ({3:F3} in)",
      p("lightL") + 2 * a.webOutY - 2 * p("armSide"), (p("lightL") + 2 * a.webOutY - 2 * p("armSide")) / 25.4,
      p("lightW") + 2 * a.webOutX - 2 * p("armEnd"), (p("lightW") + 2 * a.webOutX - 2 * p("armEnd")) / 25.4));
    double tt = a.zSeat - a.zb;
    log.AppendLine(String.Format("  tongue: {0:F2} thick (slot {1:F2} - diffuser {2:F2} - clearances), {3:F2} deep in the slot, {4:F0} long",
      tt, p("chanSlotW"), p("diffT"), a.webInX - p("tongueClrX") - a.tipX, p("tongueLen")));
    if (tt < 6) log.AppendLine("  !! tongue under 6 mm thick");
    if (a.webOutX < 0.5) log.AppendLine("  !! frame is not proud of the side of the light: bracket joggle under 0.5");
    if (a.zb < 8) log.AppendLine("  !! frame back is under 8 mm from the lamp front");
  }

  // ---------------------------------------------------------------- corner block: joins two channels, seats the diffuser corner
  static void BuildBlock(string path, string imgDir, string tag) {
    // A corner CAP: the same C section as the channel, a size bigger on the outside and the front, flush at the back.
    // The channel ends butt against its arms; its tongues go into their slots; the diffuser corner is inside it, hidden.
    // From the front only the inner rectangle of the diffuser shows. The bracket leg screws to its outside face.
    // Prints standing on that outside face (x = bumpX down), so the slot for the sheet is vertical: no support in it.
    if (!OpenOrNew(path)) return;
    Lay a = L(); LayoutReport(a);
    double lt = p("tongueLen"), tx = a.webInX - p("tongueClrX"), ty = a.webInY - p("tongueClrX");
    double[][] ell = new double[][] { new double[] { a.bumpX, a.bumpY }, new double[] { a.xe, a.bumpY }, new double[] { a.xe, a.tipY }, new double[] { a.tipX, a.tipY },
      new double[] { a.tipX, a.ys }, new double[] { a.bumpX, a.ys } };
    PZ(ell, a.zRearOut, a.zSeat, false, "body");
    PZ(Rect(a.tipX, a.ys - lt, tx, a.ys + 1), a.zb, a.zSeat, false, "side tongue");
    PZ(Rect(a.xe - lt, a.tipY, a.xe + 1, ty), a.zb, a.zSeat, false, "end tongue");
    PZ(new double[][] { new double[] { a.bumpX, a.bumpY }, new double[] { a.xe, a.bumpY }, new double[] { a.xe, a.webInY }, new double[] { a.webInX, a.webInY },
      new double[] { a.webInX, a.ys }, new double[] { a.bumpX, a.ys } }, a.zRearOut, a.zTop, false, "web");
    PZ(ell, a.zLip, a.zTop, false, "lip");
    // M3 heat-set inserts, in from the outside face: along the build direction of the print, the good way for an insert
    double sp = p("brkScrewSpan") / 2;
    // The hole is TAPERED to match the insert (8 deg included) and prints to size: no drilling. insHoleBotD is the diameter at the
    // depth of the insert's narrow end (McMaster's "hole" figure), the mouth is wider by the taper over the insert length, then a
    // short straight pocket below for the melt. A 45 deg chamfer on the mouth takes the first-layer squash (the mouth is on the bed).
    { double il = p("insLen"), rb = p("insHoleBotD") / 2, tn = Math.Tan(p("insTaperDeg") / 2 * Math.PI / 180), rt = rb + il * tn, mc = p("insMouthCham"), dp = p("pilotDepth");
      double[][] prof = { new double[] { a.bumpX + 1, rt - mc * tn + mc + 1 }, new double[] { a.bumpX - mc, rt - mc * tn }, new double[] { a.bumpX - il, rb }, new double[] { a.bumpX - dp, rb } };
      RevCutX(a.yi - sp, a.zScrew, prof, "insert hole 1");
      RevCutX(a.yi + sp, a.zScrew, prof, "insert hole 2");
      double wall = Math.Min(a.zScrew - rt - a.zRearOut, a.zSeat - a.zScrew - rt);
      log.AppendLine(String.Format("  insert holes: tapered {0:F1} deg, {1:F2} dia at the mouth to {2:F2} at {3:F1} deep, then straight to {4:F1}; mouth chamfer {5:F1}; print to size, no drilling",
        p("insTaperDeg"), 2 * rt, 2 * rb, il, dp, mc));
      log.AppendLine(String.Format("  insert holes: {0:F2} of plastic front and back at the mouth; {1:F1} beyond the hole end", wall, a.bumpX - dp - a.tipX));
      if (wall < 2.3) log.AppendLine("  !! under 2.3 mm of plastic beside the insert holes");
      if (p("pilotDepth") < p("insLen") + 1.0) log.AppendLine("  !! insert hole under 1 mm deeper than the insert");
      if (a.bumpX - p("pilotDepth") < a.tipX + 2) log.AppendLine("  !! insert hole nearly through the block");
      if (a.yi - p("brkW") / 2 < a.ys + 1) log.AppendLine("  !! bracket runs off the end of the side arm"); }
    // ---- corners
    {
      double rc = p("cornerR"), cc = 0.586 * rc, zm = (a.zRearOut + a.zTop) / 2;
      // Bumper corner: a round would be tangent to the bed where the print starts, so it begins as a 45 deg chamfer on the
      // bed side and runs into the radius (chamfer 0.586 R, then R on its upper edge: the arc ends R from the corner).
      ChamE(cc, "bumper corner, bed side", V(a.bumpX, a.bumpY, zm));
      Fil(rc, "bumper corner", V(a.bumpX - cc, a.bumpY, zm));
      // Sheet corner relief. This corner used to carry a fillet (rimInR): the sharp tip of the sheet rode up on it and stopped the
      // cap about 0.3 short of the sheet edges, with the tip jammed and no room to grow. Now a round pocket centred on the corner,
      // the height of the sheet slot only, so the cap can seat on both edges and the tip touches nothing.
      { double rr = p("sheetReliefR"), lig = (a.bumpX - a.webInX) * Math.Sqrt(2) - rc * (Math.Sqrt(2) - 1) - rr;
        Cyls(new double[][] { new double[] { sgn * a.webInX, a.webInY, 2 * rr } }, a.zSeat, a.zLip, true, "sheet corner relief");
        log.AppendLine(String.Format("  sheet corner relief: R {0:F1} round pocket on the inside corner of the web, slot height only; tip of the sheet {1:F2} from its wall as designed, {0:F1} with the cap hard on both edges; about {2:F1} of web left on the diagonal",
          rr, Math.Sqrt(p("edgeW") * p("edgeW") + p("edgeL") * p("edgeL")) + rr, lig));
        if (lig < 1.8) log.AppendLine("  !! under 1.8 mm of web left behind the sheet corner relief"); }
      Fil(p("revealR"), "reveal corner", V(a.tipX, a.tipY, (a.zLip + a.zTop) / 2));
      Fil(p("revealR"), "body inside corner", V(a.tipX, a.tipY, (a.zRearOut + a.zSeat) / 2));
      ChamE(1.5, "arm ends", V(a.bumpX, a.ys, zm), V(a.xe, a.bumpY, zm));
      double zt = (a.zb + a.zSeat) / 2;
      ChamE(1.2, "tongue lead-in", V(tx, a.ys - lt, zt), V(a.tipX, a.ys - lt, zt), V(a.xe - lt, ty, zt), V(a.xe - lt, a.tipY, zt));
      Cham(p("frontCham"), "front face chamfer", V((a.tipX + a.bumpX) / 2, a.ys + 6, a.zTop));
      Cham(p("bedChamSmall"), "back face chamfer", V((a.tipX + a.bumpX) / 2, a.ys + 6, a.zRearOut));
      log.AppendLine(String.Format("  corner cap: web {0:F2} thick, lip {1:F2} thick over the sheet, body {2:F2}; slot for the sheet {3:F2} (sheet {4:F2}); front {5:F1} proud of the channel, back flush",
        a.bumpX - a.webInX, a.zTop - a.zLip, a.zSeat - a.zRearOut, a.zLip - a.zSeat, p("diffT"), p("proud")));
      log.AppendLine(String.Format("  sheet corner goes {0:F1} / {1:F1} under the lip; reveal lines up with the channel leg tips", a.webInX - p("edgeW") - a.tipX, a.webInY - p("edgeL") - a.tipY));
      log.AppendLine(String.Format("  prints on its outside face: {0:F0} tall; side tongue hangs {1:F1} above the bed for {2:F0} mm (support there, nowhere else)", a.bumpX - (a.xe - lt), a.bumpX - tx, lt));
    }
    Finish(path, tag, 0.15, 0.2, 0.35, imgDir, "*Isometric", 7);
  }

  // ---------------------------------------------------------------- bracket: frame corner to the M6 insert on the angled face
  static bool footMode = false;
  // The lamp leans back leanDeg. In the lamp's own frame the table is then a plane that drops toward the front:
  // y of the table under a point at z. The sole is footTailT thick at its tail and grows forward.
  static double Yb(double z) { return p("footEndClr") + p("footTailT") + (z + p("lightH") + p("footBack")) * Math.Tan(p("leanDeg") * Math.PI / 180); }
  static void BuildBracket(string path, string imgDir, string tag) {
    if (!OpenOrNew(path)) return;
    Lay a = L();
    double t = p("brkT"), tp = p("padT"), lp = p("padLen"), bw = p("brkW"), sf = p("lightSideFlat");
    double y1 = a.yi - bw / 2, y2 = a.yi + bw / 2;
    double zJ = a.zb - p("jogBelow") - a.jog;
    double sc = p("sideClr");                                       // air between the leg and the side flat: the M6 seats the pad, the leg floats
    if (sc > a.jog - 0.3) log.AppendLine("  !! side clearance leaves no joggle");
    double ex = lp * a.dX, ez = -sf + lp * a.dZ;                      // far end of the pad on the angled face
    double ox = tp * a.nX, oz = -sf + tp * a.nZ;                      // pad outer line passes through here, direction d
        // Inside corner at the bend: a round relief, not a sharp notch (the first print cracked from the sharp corner
    // when the angle was opened by hand). It also keeps the corner off the radius of the sheet-metal bend.
    double rr = p("cornerRelR"), kb = p("cornerRelBack");
    double p0x = sc, p0z = -sf + sc * a.dZ / a.dX;
    double bl = Math.Sqrt(a.dX * a.dX + (1 + a.dZ) * (1 + a.dZ)), bX = a.dX / bl, bZ = (1 + a.dZ) / bl;   // bisector, pointing into the housing
    double crx = p0x - kb * bX, crz = p0z - kb * bZ, db = bZ;                                             // relief centre, inside the plastic; db = d.b = u.b
    double sm = -kb * db + Math.Sqrt(kb * kb * db * db - kb * kb + rr * rr);                              // mouth: this far along each face from the corner
    double aX = p0x + sm * a.dX - crx, aZ = p0z + sm * a.dZ - crz;
    double wX = -bZ, wZ = bX; if (aX * wX + aZ * wZ < 0) { wX = -wX; wZ = -wZ; }   // so the arc runs from the pad face round to the leg face
    double phi = Math.Acos(Math.Max(-1, Math.Min(1, -(aX * bX + aZ * bZ) / rr)));
    List<double[]> prof = new List<double[]>();
    int ns = 14;
    for (int i = 0; i <= ns; i++) { double th = -phi + 2 * phi * i / ns; prof.Add(new double[] { crx + rr * (-Math.Cos(th) * bX - Math.Sin(th) * wX), crz + rr * (-Math.Cos(th) * bZ - Math.Sin(th) * wZ) }); }
    double xo = a.jog + t, so = (xo - ox) / a.dX, zO2 = oz + so * a.dZ;   // leg outer face runs straight down to the pad: no outside joggle, a thicker leg
    prof.Add(new double[] { sc, zJ + sc }); prof.Add(new double[] { a.jog, zJ + a.jog }); prof.Add(new double[] { a.jog, a.zLeg });
    prof.Add(new double[] { xo, a.zLeg }); prof.Add(new double[] { xo, zO2 });
    prof.Add(new double[] { ex + tp * a.nX, ez + tp * a.nZ }); prof.Add(new double[] { ex, ez });
    { double diag = Math.Sqrt((xo - p0x) * (xo - p0x) + (zO2 - p0z) * (zO2 - p0z));
      log.AppendLine(String.Format("  corner relief: r {0:F1}, mouth {1:F2} along each face, {2:F2} deep; plastic left across the corner about {3:F1}", rr, sm, kb + rr, diag - kb - rr));
      if (diag - kb - rr < 5.5) log.AppendLine("  !! under 5.5 mm of plastic across the bend"); }
    PY(prof.ToArray(),
      y1, y2, false, "leg and pad");
    // relief over the sheet-metal screw head on the side flat near the end of the housing
    PX(Rect(y2 - p("relLen"), -p("relZfar"), y2 + 1, -p("relZnear")), -1, sc + p("relDepth"), true, "screw head relief");
    // the head it clears: centre headFromEnd from the end of the housing, headBack behind the front, dia headD, height headH
    { double m1 = (-p("headFromEnd") - p("headD") / 2) - (y2 - p("relLen")), m2 = p("relZfar") - (p("headBack") + p("headD") / 2), m3 = (p("headBack") - p("headD") / 2) - p("relZnear"), m4 = sc + p("relDepth") - p("headH");
      log.AppendLine(String.Format("  screw head relief margins: along length {0:F1}, toward bend {1:F1}, toward front {2:F1}, depth {3:F1}", m1, m2, m3, m4));
      if (m1 < 1 || m2 < 1.5 || m3 < 1.5 || m4 < 0.5) log.AppendLine("  !! screw head relief is too tight");
      if (p("relZfar") > sf - 2) log.AppendLine("  !! relief runs into the bend"); }
    // The lens frame of the fixture laps back over the side flat and over the end, stripT proud (test print, Nov 24:
    // the leg sat on the lap and held the pad off the angled face). Step the inside of the leg clear of it.
    double stX = p("stripT") + p("stripClr"), stZ = -(p("stripW") + p("stripBack")), endRelY = p("stripT") + p("endHeadH") + p("endRelClr");
    if (!footMode) PY(Rect(-1, stZ, stX, zJ + stX), y1 - 1, y2 + 1, true, "lens frame relief, side");
    log.AppendLine(String.Format("  lens frame lap: {0:F1} proud, taken as {1:F0} wide; leg stepped to x {2:F1} from z {3:F0} forward ({4:F1} clear); leg {5:F1} thick there",
      p("stripT"), p("stripW"), stX, stZ, p("stripClr"), xo - stX));
    // M6 slot through the pad, long axis down the slope, and a relief for the flange of the insert
    double hs = p("m6Slot") / 2, r = p("m6Clr") / 2;
    RevCutY(a.yi, a.cX - 1.0 * a.nX, a.cZ - 1.0 * a.nZ, a.nX, a.nZ, 1.0 + p("flangeRelDepth"), p("flangeRelD") / 2, "insert flange relief");
    RevCutY(a.yi, a.cX + hs * a.dX - a.nX, a.cZ + hs * a.dZ - a.nZ, a.nX, a.nZ, tp + 2, r, "M6 slot end 1");
    RevCutY(a.yi, a.cX - hs * a.dX - a.nX, a.cZ - hs * a.dZ - a.nZ, a.nX, a.nZ, tp + 2, r, "M6 slot end 2");
    PY(new double[][] {
      new double[] { a.cX - hs * a.dX - a.nX, a.cZ - hs * a.dZ - a.nZ }, new double[] { a.cX + hs * a.dX - a.nX, a.cZ + hs * a.dZ - a.nZ },
      new double[] { a.cX + hs * a.dX + (tp + 1) * a.nX, a.cZ + hs * a.dZ + (tp + 1) * a.nZ }, new double[] { a.cX - hs * a.dX + (tp + 1) * a.nX, a.cZ - hs * a.dZ + (tp + 1) * a.nZ } },
      a.yi - r, a.yi + r, true, "M6 slot middle");
    double sp = p("brkScrewSpan") / 2;
    CX(new double[][] { new double[] { a.yi - sp, a.zScrew, p("screwClrD") }, new double[] { a.yi + sp, a.zScrew, p("screwClrD") } },
      a.jog - 1, a.jog + t + 1, true, "screw holes");
    log.AppendLine(String.Format("  bracket: leg {0:F1} thick, air span front of lamp to block {1:F1}, pad {2:F1} long on a {3:F1} face, {4:F1} of pad beyond the slot",
      t, a.zb, lp, p("lightSlopeLen"), lp - p("insUpSlope") - hs - r));
    { double fy = (p("m6Clr") - 6.0) / 2 + p("brkSeatClr");
      log.AppendLine(String.Format("  float per bracket: {0:F1} along the length (M6 in a {1:F1} wide slot, plus the seat), {2:F1} along the slope; needs a washer of {3:F0} OD or more", fy, p("m6Clr"), (p("m6Slot") + p("m6Clr") - 6.0) / 2, p("m6Clr") + 7));
      if (p("flangeRelD") < p("insFlangeD") + 2 * ((p("m6Clr") - 6.0) / 2) + 0.5) log.AppendLine("  !! flange relief too small for the float along the length"); }
    if (lp > p("lightSlopeLen") - 1) log.AppendLine("  !! pad runs past the angled face");
    if (lp - p("insUpSlope") - hs - r < 3) log.AppendLine("  !! under 3 mm of pad beyond the M6 slot");
    if (bw / 2 - sp - p("screwClrD") / 2 < 2.5) log.AppendLine("  !! bracket screws under 2.5 mm from the edge");
    if (p("relDepth") > t - 2.5) log.AppendLine("  !! under 2.5 mm of leg left over the screw head relief");
    // bending check on the leg: a sideways knock F on the frame corner, taken across the air span
    double F = p("knockN"), arm = a.zScrew, I = bw * t * t * t / 12, sig = F * arm * (t / 2) / I, defl = F * arm * arm * arm / (3 * p("petgcfE") * I);
    log.AppendLine(String.Format("  leg bending: {0:F0} N sideways at the frame, arm {1:F1} mm -> {2:F1} MPa, {3:F2} mm deflection (E {4:F0} MPa assumed)", F, arm, sig, defl, p("petgcfE")));
    if (footMode) {
      // FOOT: the bracket for a bottom corner, carried on past the end of the housing (+y) to a sole on the table.
      // Prints sole down. The underside is the table plane Yb(z): a wedge, so the lamp leans back leanDeg.
      double fc = p("footClr"), yTop = p("footEndClr"), yBot = Yb(a.zTop + p("footFwd")) + 2, yThin = a.bumpY + p("footBlockClr");
      double zRear = -(p("lightH") + p("footBack")), zStep = a.zRearOut - 0.8, zFwd = a.zTop + p("footFwd");
      double xIn = ex - 0.1, zLegTop = zJ + sc;
      // leg and pad carried down to the sole, standing fc off the housing (end-cap laps, screw heads)
      double fs = (fc + 0.3 - fc * a.nX) / a.dX, fz = -sf + fc * a.nZ + fs * a.dZ;
      PY(new double[][] { new double[] { fc + 0.3, fz }, new double[] { fc + 0.3, zLegTop }, new double[] { xo, zLegTop }, new double[] { xo, zO2 },
        new double[] { ex + tp * a.nX, ez + tp * a.nZ }, new double[] { ex + fc * a.nX, ez + fc * a.nZ } }, y2 - 0.5, yTop + 0.5, false, "foot leg");
      PY(Rect(xIn, zRear, xo, zStep), yTop, yBot, false, "sole under the housing");
      PY(Rect(xIn, zStep - 0.5, xo, zFwd), yThin, yBot, false, "sole under the block");
      // ---- from the first test print of the foot (Nov 24)
      // The M6 is on the angled face, so its axis lies in the plane of the housing end. Nothing but friction stopped
      // the foot swivelling about it, and the housing end did not touch the sole at all (it stood on one screw head).
      // TAB: the sole carried in under the housing end, toward the centre line of the lamp, across the M6 axis.
      double xT = xIn - p("footTabIn"), zT1 = -p("footTabZ1"), zT2 = -p("footTabZ2");
      PY(Rect(xT, zT1, xIn + 1, zT2), yTop, yBot, false, "sole tab under the housing");
      // LANDS: two raised pads that touch the END of the housing (y = 0), one each side of the M6 axis. Whichever way
      // the foot tries to swivel, one of them is driven into the end of the housing. They also carry the weight,
      // straight down through the sole, and set the foot's height: push up until both touch, then tighten.
      double[][] lands = new double[][] { new double[] { p("landAx0"), p("landAz0"), p("landAx1"), p("landAz1") }, new double[] { p("landBx0"), p("landBz0"), p("landBx1"), p("landBz1") } };
      PY(Rect(lands[0][0], lands[0][1], lands[0][2], lands[0][3]), 0, yTop + 0.5, false, "land A");
      PY(Rect(lands[1][0], lands[1][1], lands[1][2], lands[1][3]), 0, yTop + 0.5, false, "land B");
      // RELIEFS for the lens frame lap, on the side and on the end, and for the screw through it at the corner of the end
      PY(Rect(-1, stZ, stX, zJ + stX), y1 - 1, endRelY, true, "lens frame relief, side");
      PY(Rect(xIn - 1, stZ, stX, zStep + 0.5), yTop - 1, endRelY, true, "lens frame and corner screw relief, end");
      { double[] lev = new double[2];
        for (int i = 0; i < 2; i++) {
          double lx = (lands[i][0] + lands[i][2]) / 2, lz = (lands[i][1] + lands[i][3]) / 2;
          lev[i] = -a.nZ * (lx - a.cX) + a.nX * (lz - a.cZ);
          foreach (double cx in new double[] { lands[i][0], lands[i][2] }) foreach (double cz in new double[] { lands[i][1], lands[i][3] }) {
            double edge = cz < -sf ? (cz + sf) * a.dX / a.dZ : 0;
            if (cx > edge - 2 || cz < -p("lightWingDepth") + 2 || cz > stZ - 1) log.AppendLine(String.Format("  !! land {0} corner at x {1:F0}, z {2:F0} is off the flat of the housing end", i == 0 ? "A" : "B", cx, cz));
          }
          if (i == 1 && (lands[i][0] < xT + 3 || lands[i][1] < zT1 + 3 || lands[i][3] > zT2 - 3)) log.AppendLine("  !! land B is at the edge of the tab");
        }
        log.AppendLine(String.Format("  anti-swivel: land A bears on the housing end {0:F0} mm one side of the M6 axis, land B {1:F0} mm the other side; tab reaches x {2:F0}, z {3:F0}..{4:F0}",
          lev[0], -lev[1], xT, zT1, zT2));
        if (lev[0] * lev[1] > 0 || Math.Abs(lev[0]) < 10 || Math.Abs(lev[1]) < 10) log.AppendLine("  !! lands do not straddle the M6 axis by 10 mm each");
        log.AppendLine(String.Format("  end relief: sole top dropped to {0:F1} below the housing end from z {1:F0} forward; the corner screw head stands {2:F1} proud there (lap {3:F1} + head {4:F1})",
          endRelY, stZ, p("stripT") + p("endHeadH"), p("stripT"), p("endHeadH"))); }
      // toe: the sole simply runs on footFwd in front of the cap at the same level; its front top edge is rounded off below
      // 45 deg gusset under the part of the leg that sits in the block seat, outside the bumper face of the block
      double gx = a.bumpX + 0.4, gz = a.zLeg - (yThin - y2);
      PX(new double[][] { new double[] { y2 - 0.5, zLegTop - 0.5 }, new double[] { y2 - 0.5, a.zLeg }, new double[] { y2, a.zLeg }, new double[] { yThin + 0.5, gz }, new double[] { yThin + 0.5, zLegTop - 0.5 } },
        gx, xo, false, "seat gusset");
      // diagonal brace: a web outside the side plane of the housing, from the top of the bracket down to the tail of the sole.
      // With bumpers at the two ends of the sole the lamp's weight lands between them; this makes that span a deep beam (creep).
      double zW = zO2 + 1, bx0 = fc + 0.3, rT = p("footCornerR");
      // The M6 is driven from outside along the normal to the angled face. That line crosses the brace; the brace is
      // held below a tool cylinder of radius toolR about it (it drops steeply behind the leg, then runs shallow to the tail).
      double tR = p("toolR"), s0 = (bx0 - a.cX) / a.nX, zLos = a.cZ + s0 * a.nZ, zC = zLos + tR / Math.Abs(a.nX), yCut = a.yi + tR;
      if (zC > zW - 10) { zC = zW - 10; log.AppendLine("  !! brace cannot clear the M6 tool line"); }
      PX(new double[][] { new double[] { yTop + 0.5, zRear + rT }, new double[] { yTop - p("footBraceEnd"), zRear + rT }, new double[] { yCut, zC },
        new double[] { y1, zW - 6 }, new double[] { y1, zW }, new double[] { yTop + 0.5, zW } },
        bx0, xo, false, "side brace");
      { double wt = xo - bx0, zh = -p("lightWingDepth"), hh = (Yb(zh) - yCut) + (y1 < yCut && zh > zC ? (yCut - y1) * (zh - zC) / (zW - 6 - zC) : 0);   // depth of web + sole where the housing ends
        // Balance: the fixture alone balances cgInset in front of the wing back (Robert, on a straightedge). The frame and
        // diffuser pull the centre of gravity of the whole lamp forward. Bumpers sit bumpIn from each end of the sole.
        double bi = p("bumpIn"), wFix = p("lampWeightN") - p("frameWeightN"), zFix = -(p("lightWingDepth") - p("cgInset")), zFrm = (a.zRearOut + a.zFront) / 2;
        double zcg = (wFix * zFix + p("frameWeightN") * zFrm) / p("lampWeightN"), ycg = -p("lightL") / 2, th = p("leanDeg") * Math.PI / 180, cth = Math.Cos(th), sth = Math.Sin(th);
        double zBf = zFwd - bi, zBr = zRear + bi, yBf = Yb(zBf) + p("bumpH"), yBr = Yb(zBr) + p("bumpH");
        // along the table (t) and up from it (u), in the lamp's z, y: t = (cos, sin), u = (sin, -cos)
        double dR = (zcg - zBr) * cth + (ycg - yBr) * sth, hR = (zcg - zBr) * sth - (ycg - yBr) * cth;
        double dF = -((zcg - zBf) * cth + (ycg - yBf) * sth), hF = (zcg - zBf) * sth - (ycg - yBf) * cth;
        log.AppendLine(String.Format("  balance: fixture at z {0:F0}, frame at z {1:F0} -> whole lamp at z {2:F0}; centre {3:F0} above the table (taken at mid-length); lamp leans back {4:F1} deg", zFix, zFrm, zcg, hR, p("leanDeg")));
        log.AppendLine(String.Format("  tips BACKWARD after a further {0:F1} deg ({1:F0} mm of stance behind the centre), FORWARD after {2:F1} deg ({3:F0} mm in front)",
          Math.Atan2(dR, hR) * 180 / Math.PI, dR, Math.Atan2(dF, hF) * 180 / Math.PI, dF));
        { double v1b = Math.Atan2(zcg + p("lightH"), p("lightL") / 2) * 180 / Math.PI, v1f = Math.Atan2(a.zFront - zcg, p("lightL") / 2) * 180 / Math.PI, v1l = p("v1LeanDeg");
          log.AppendLine(String.Format("  for comparison, v1 stands on its frame front and the back of the driver channel, leaning back {0:F1} deg: {1:F1} deg backward, {2:F1} deg forward", v1l, v1b - v1l, v1f + v1l)); }
        double span = dR + dF, la = dF, lb = dR, W = p("lampWeightN") / 2;
        { double Rf = W * lb / span, toeArm = Math.Max(0, zBf - a.zTop), Zt = (xo - xIn) * Math.Pow(Yb(a.zTop) - yThin, 2) / 6;
          log.AppendLine(String.Format("  toe: front bumper carries {0:F0} N, {1:F0} mm in front of the block -> {2:F2} MPa sustained at the root ({3:F1} deep there)", Rf, toeArm, Rf * toeArm / Zt, Yb(a.zTop) - yThin)); }
        // Section where the housing ends (the brace is at its shallowest under load there): sole as flange, brace as web.
        double Mb = W * la * lb / span, Mh = W * la / span * (zh - zBr);
        double tf = Yb(zh) - yTop, bf = xo - xIn, hw = hh - tf, Af = bf * tf, Aw = wt * hw, yc = (Af * tf / 2 + Aw * (tf + hw / 2)) / (Af + Aw);
        double It = bf * tf * tf * tf / 12 + Af * (yc - tf / 2) * (yc - tf / 2) + wt * hw * hw * hw / 12 + Aw * (tf + hw / 2 - yc) * (tf + hw / 2 - yc);
        double sg = Mh * Math.Max(yc, hh - yc) / It, sg0 = Mb * (tf / 2) / (bf * tf * tf * tf / 12);
        log.AppendLine(String.Format("  foot span between bumpers {0:F0}; {1:F0} N per foot landing {2:F0} from the front one -> {3:F0} N.mm at the load, {4:F0} where the housing ends", span, W, la, Mb, Mh));
        log.AppendLine(String.Format("  foot sustained bending where the housing ends: sole + brace {0:F0} deep -> {1:F2} MPa (sole alone, at the load, would be {2:F1} MPa)", hh, sg, sg0));
        // The tail is a cantilever from where the housing ends back to the rear bumper, and both the wedge and the brace
        // thin out along it: find the worst section rather than trust the one at the housing.
        double worst = 0, zWorst = 0, Rr = W * la / span;
        for (double zz = zBr + 2; zz <= zh; zz += 2) {
          double top = zz >= zC ? yCut + (y1 - yCut) * Math.Min(1, (zz - zC) / (zW - 6 - zC)) : (zz < zRear + rT ? yTop : (yTop - p("footBraceEnd")) + (yCut - (yTop - p("footBraceEnd"))) * (zz - zRear - rT) / (zC - zRear - rT));
          double f1 = Yb(zz) - yTop, w1 = Math.Max(0, yTop - top), A1 = bf * f1, A2 = wt * w1, c1 = (A1 * f1 / 2 + A2 * (f1 + w1 / 2)) / (A1 + A2);
          double I1 = bf * f1 * f1 * f1 / 12 + A1 * (c1 - f1 / 2) * (c1 - f1 / 2) + wt * w1 * w1 * w1 / 12 + A2 * (f1 + w1 / 2 - c1) * (f1 + w1 / 2 - c1);
          double s1 = Rr * (zz - zBr) * Math.Max(c1, f1 + w1 - c1) / I1;
          if (s1 > worst) { worst = s1; zWorst = zz; }
        }
        double tipE = Rr * Math.Pow(zh - zBr, 3) / (3 * p("petgE") * It);
        log.AppendLine(String.Format("  creep: rear bumper carries {0:F1} N, front {1:F1} N per foot; worst sustained stress along the tail {2:F2} MPa at z {3:F0}", Rr, W - Rr, worst, zWorst));
        log.AppendLine(String.Format("  creep: tail deflects about {0:F2} mm at the bumper when new (E {1:F0}); three times that over years would add {2:F2} deg of lean", tipE, p("petgE"), Math.Atan2(3 * tipE, span) * 180 / Math.PI));
        if (worst > 1.0) log.AppendLine("  !! sustained stress over 1 MPa: creep"); }
      log.AppendLine(String.Format("  M6 line of sight: tool axis crosses the brace at z {0:F0}; brace top held {1:F0} below the axis from z {2:F0} back to the tail", zLos, tR, zC));
      // everything below the table plane comes off: this face is the bed face of the print
      PX(new double[][] { new double[] { Yb(zRear - 5), zRear - 5 }, new double[] { Yb(zFwd + 5), zFwd + 5 }, new double[] { yBot + 5, zFwd + 5 }, new double[] { yBot + 5, zRear - 5 } },
        xT - 5, xo + 5, true, "table plane");
      // the side screw-head relief carried through to the end
      PX(Rect(y2 - p("relLen"), -p("relZfar"), yTop - 0.2, -p("relZnear")), -1, sc + p("relDepth"), true, "screw head relief to the end");
      double thin = Yb(zStep) - yThin, wS = xo - xIn;
      log.AppendLine(String.Format("  foot: sole {0:F1} wide, z {1:F1}..{2:F1} ({3:F0} long); a wedge {4:F1} thick at the tail, {5:F1} under the front of the housing, {6:F1} at the toe root",
        wS, zRear, zFwd, zFwd - zRear, Yb(zRear) - yTop, Yb(0) - yTop, Yb(a.zTop) - yThin));
      log.AppendLine(String.Format("  foot: housing end sits {0:F1} above the sole (end screw heads {1:F1}), cap {2:F1} above it; the housing end is {3:F1} off the table at its back edge and {4:F1} at its front",
        yTop, p("endHeadH"), p("footBlockClr"), Yb(-p("lightH")), Yb(0)));
      log.AppendLine(String.Format("  foot: stance front to back {0:F0} mm, {1:F0} behind the housing back, {2:F0} in front of the frame", zFwd - zRear, p("footBack"), p("footFwd")));
      if (yTop < p("endHeadH") + 0.5) log.AppendLine("  !! sole under 0.5 clear of the end screw heads");
      if (thin < 2.5) log.AppendLine("  !! sole under the block is under 2.5 thick");
      if (gz < zLegTop) log.AppendLine("  !! gusset geometry inverted");
    }
    // ---- corners. Edges that stand vertical in the print get radii. Corners that touch the bed get 45 deg chamfers
    // (a round tangent to the bed is an overhang). Bracket prints on its y1 face; the foot prints on its sole.
    {
      double rv = p("visR"), re = p("edgeR"), xm = (a.jog + xo) / 2, ym = (y1 + y2) / 2;
      double pmx = ex + tp / 2 * a.nX, pmz = ez + tp / 2 * a.nZ;
      if (footMode) {
        Fil(rv, "leg top corner", V(xm, y1, a.zLeg));
        Fil(rv, "pad end corner", V(pmx, y1, pmz));
      } else {
        ChamE(rv, "leg top corners", V(xm, y1, a.zLeg), V(xm, y2, a.zLeg));
        ChamE(rv, "pad end corners", V(pmx, y1, pmz), V(pmx, y2, pmz));
        Fil(p("bendOutR"), "outside of the bend", V(xo, ym, zO2));
      }
      Fil(rv * 0.75, "leg top outer edge", V(xo, ym, a.zLeg));
      Fil(rv * 0.75, "pad end outer edge", V(ex + tp * a.nX, ym, ez + tp * a.nZ));
      Fil(re, "leg top inner edge", V(a.jog, ym, a.zLeg));
      Fil(re, "pad end inner edge", V(ex, ym, ez));
      if (footMode) {
        double fc = p("footClr"), yTop = p("footEndClr"), yThin = a.bumpY + p("footBlockClr");
        double zRear = -(p("lightH") + p("footBack")), zFwd = a.zTop + p("footFwd"), xIn = ex - 0.1, bx0 = fc + 0.3;
        double fs = (fc + 0.3 - fc * a.nX) / a.dX, fz = -sf + fc * a.nZ + fs * a.dZ, rT = p("footCornerR");
        double s0 = (bx0 - a.cX) / a.nX, zC = a.cZ + s0 * a.nZ + p("toolR") / Math.Abs(a.nX), yCut = a.yi + p("toolR"), zW = zO2 + 1;
        Fil(rT, "sole tail corners", V(xo, yTop + 2, zRear), V(xIn, yTop + 2, zRear));
        Fil(p("footFrontR"), "sole front corners", V(xo, Yb(zFwd) - 3, zFwd), V(xIn, Yb(zFwd) - 3, zFwd));
        { double xT = xIn - p("footTabIn"), zT1 = -p("footTabZ1"), zT2 = -p("footTabZ2");
          Fil(p("footTabR"), "tab corners", V(xT, yTop + 2, zT1), V(xT, yTop + 2, zT2));
          Fil(3, "tab roots", V(xIn, yTop + 2, zT1), V(xIn, yTop + 2, zT2)); }
        Fil(p("braceKinkR"), "brace kink", V((bx0 + xo) / 2, yCut, zC));
        Fil(rv, "brace top corner", V((bx0 + xo) / 2, y1, zW - 6));
        Fil(p("insideR"), "inside corner of the foot leg", V(fc + 0.3, (y2 + yTop) / 2, fz));
        Fil(p("insideR"), "brace to sole", V(bx0, yTop, zC - 20));
        FilC(p("soleTopR"), "sole top edge, tail", V(xIn, yTop, zRear + 40));
        FilC(p("toeNoseR"), "toe top edge", V((xIn + xo) / 2, yThin, zFwd));
        Cham(p("bedCham"), "bed face chamfer", V(xIn + 15, Yb(zRear + 40), zRear + 40));
      } else {
        // bed-face edges, chained along tangents; the small relief arc at the inside of the bend is left as it is
        ChamC(p("bedChamSmall"), "bed face chamfer", V(xo, y1, 0), V(sc, y1, -22), V(stX, y1, -5), V(a.jog, y1, a.zLeg - 6),
          V(ex / 2 + tp * a.nX, y1, (ez - sf) / 2 + tp * a.nZ), V(ex / 2, y1, (ez - sf) / 2));
        FilC(re, "top face edge", V(xo, y2, 0));
        double left = Math.Sqrt((xo - sc) * (xo - sc) + (zO2 + sf) * (zO2 + sf)) - p("cornerRelBack") - p("cornerRelR") - 0.147 * p("bendOutR");
        log.AppendLine(String.Format("  plastic across the bend after the outside radius: about {0:F1}", left));
        if (left < 5.5) log.AppendLine("  !! under 5.5 mm of plastic across the bend");
      }
    }
    Finish(path, tag, 0.15, 0.2, 0.35, imgDir, "*Isometric", 7);
  }

  // ---------------------------------------------------------------- mock of one corner: housing, diffuser, channel stubs (hand A)
  static void BuildMock(string path, string imgDir) {
    if (!OpenOrNew(path)) return;
    Lay a = L(); sgn = 1;
    double far = -p("mockExtent"), sf = p("lightSideFlat"), wd = p("lightWingDepth");
    double bx = p("lightSlopeLen") * a.dX;
    PY(new double[][] { new double[] { 0, 0 }, new double[] { 0, -sf }, new double[] { bx, -wd }, new double[] { far, -wd }, new double[] { far, 0 } }, far, 0, false, "housing");
    PZ(Rect(far, far, a.webInX - p("edgeW"), a.webInY - p("edgeL")), p("gap"), a.zf, false, "diffuser");
    PY(new double[][] {
      new double[] { a.tipX, a.zRearOut }, new double[] { a.webOutX, a.zRearOut }, new double[] { a.webOutX, a.zFront }, new double[] { a.tipX, a.zFront },
      new double[] { a.tipX, a.zf }, new double[] { a.webInX, a.zf }, new double[] { a.webInX, a.zRearIn }, new double[] { a.tipX, a.zRearIn } },
      far, a.ys, false, "side channel");
    PX(new double[][] {
      new double[] { a.tipY, a.zRearOut }, new double[] { a.webOutY, a.zRearOut }, new double[] { a.webOutY, a.zFront }, new double[] { a.tipY, a.zFront },
      new double[] { a.tipY, a.zf }, new double[] { a.webInY, a.zf }, new double[] { a.webInY, a.zRearIn }, new double[] { a.tipY, a.zRearIn } },
      far, a.xe, false, "end channel");
    CX(new double[][] { new double[] { -p("headFromEnd"), -p("headBack"), p("headD") } }, -1, p("headH"), false, "side screw head");
    { double st = p("stripT"), sw2 = p("stripW");
      PY(Rect(far, -sw2, st, 0), far, st, false, "lens frame lap");
      List<double[]> ring = new List<double[]>();
      for (int i = 0; i < 20; i++) ring.Add(new double[] { -p("cornerScrewX") + p("cornerScrewD") / 2 * Math.Cos(i * Math.PI / 10), -p("cornerScrewZ") + p("cornerScrewD") / 2 * Math.Sin(i * Math.PI / 10) });
      PY(ring.ToArray(), -1, st + p("endHeadH"), false, "corner screw head on the end"); }
    RevCutYAdd(a.yi, a.cX - 1.0 * a.nX, a.cZ - 1.0 * a.nZ, a.nX, a.nZ, 1.0 + p("insFlangeH"), p("insFlangeD") / 2, "insert flange");
    Finish(path, "lb_mock_corner", 0.75, 0.75, 0.75, imgDir, "*Isometric", 7);
  }

  // ---------------------------------------------------------------- spacer: fills the slot behind the diffuser, mid-span
  // Same section as the tongues of the corner blocks. Epoxied to the channel (rear leg and web), NOT to the sheet:
  // a push on the front of the diffuser goes straight into the rear leg in compression, and no bond is asked to hold it.
  // Own frame: x along the channel, y into the slot from the web (y = 0), z through the thickness. Prints flat.
  static void BuildSpacer(string path, string imgDir) {
    if (!OpenOrNew(path)) return;
    Lay a = L(); sgn = 1;
    double th = a.zSeat - a.zb, d = p("chanSlotDepth") - p("spacerShort"), c = p("spacerCham"), len = p("spacerLen");
    PX(new double[][] { new double[] { 0, c }, new double[] { c, 0 }, new double[] { d, 0 }, new double[] { d, th }, new double[] { c, th }, new double[] { 0, th - c } }, 0, len, false, "spacer");
    double sideFree = p("diffL") + 2 * p("edgeL") + 2 * p("chanFloor") - 2 * p("armSide") - 2 * p("tongueLen"), endFree = p("diffW") + 2 * p("edgeW") + 2 * p("chanFloor") - 2 * p("armEnd") - 2 * p("tongueLen");
    int ns = (int)p("spacerPerSide"), ne = (int)p("spacerPerEnd");
    log.AppendLine(String.Format("  spacer: {0:F2} thick (same as the tongues), {1:F1} into a {2:F2} slot, {3:F0} long, {4:F1} chamfer on the web-side edges", th, d, p("chanSlotDepth"), len, c));
    log.AppendLine(String.Format("  side channel: {0:F0} between tongues, {1} spacers -> {2:F0} of unsupported sheet edge between supports", sideFree, ns, (sideFree - ns * len) / (ns + 1)));
    log.AppendLine(String.Format("  end channel: {0:F0} between tongues, {1} spacers -> {2:F0} between supports; {3} spacers in all", endFree, ne, (endFree - ne * len) / (ne + 1), 2 * ns + 2 * ne));
    Finish(path, "lb_spacer", 0.15, 0.2, 0.35, imgDir, "*Isometric", 7);
  }

  // ---------------------------------------------------------------- whole lamp, for looking at
  // Global frame: X across the width (0 at the centre), Y along the length (0 at the centre, +Y is the TOP end,
  // the feet are at -Y), Z toward the viewer (0 at the front edge of the housing). SolidWorks shows Y up.
  // The housing, diffuser and channels are stand-ins built from the same parameters; they are not print parts.
  static void BuildHousing(string path, string imgDir) {
    if (!OpenOrNew(path)) return;
    Lay a = L(); sgn = 1;
    double W2 = p("lightW") / 2, L2 = p("lightL") / 2, sf = p("lightSideFlat"), wd = p("lightWingDepth"), run = -p("lightSlopeLen") * a.dX, cw = p("sdChanW") / 2, H = p("lightH");
    // driver channel: body sdChanW wide (measured Nov 24), lid sdLidW wide with a skirt, top of the lid at z = -H. (lightChanW is the same width from the Nov 23 sketch: 3.32 in, first misread as 3.92. Not used; sdLidW is the caliper reading.)
    // Hanger hardware as one block, taken as centred on the length.
    double lw = p("sdLidW") / 2, zs = -(H - p("sdSkirtH")), jw = lw - p("sdJunkIn");
    PY(new double[][] { new double[] { W2, 0 }, new double[] { W2, -sf }, new double[] { W2 - run, -wd }, new double[] { cw, -wd }, new double[] { cw, zs }, new double[] { lw, zs }, new double[] { lw, -H },
      new double[] { -lw, -H }, new double[] { -lw, zs }, new double[] { -cw, zs },
      new double[] { -cw, -wd }, new double[] { -(W2 - run), -wd }, new double[] { -W2, -sf }, new double[] { -W2, 0 } }, -L2, L2, false, "housing");
    PY(new double[][] { new double[] { jw, -H + 0.5 }, new double[] { jw, -H - p("sdJunkH") }, new double[] { -jw, -H - p("sdJunkH") }, new double[] { -jw, -H + 0.5 } },
      p("sdHandleY") - p("sdJunkLen") / 2, p("sdHandleY") + p("sdJunkLen") / 2, false, "hanger hardware");
    log.AppendLine(String.Format("  housing: driver channel body {0:F1} wide, lid {1:F1} wide, lid top {2:F0} behind the front edge; wing to lid top {3:F1}", 2 * cw, 2 * lw, H, H - wd));
    Finish(path, "lb_housing", 0.86, 0.86, 0.84, imgDir, "*Isometric", 7);
  }
  static void BuildDiffuser(string path, string imgDir) {
    if (!OpenOrNew(path)) return;
    Lay a = L(); sgn = 1;
    PZ(Rect(-p("diffW") / 2, -p("diffL") / 2, p("diffW") / 2, p("diffL") / 2), p("gap"), a.zf, false, "diffuser");
    finTransp = 0.25; Finish(path, "lb_diffuser", 0.97, 0.97, 0.95, imgDir, "*Isometric", 7); finTransp = 0;
  }
  static void BuildChannel(string path, string imgDir, bool side) {
    if (!OpenOrNew(path)) return;
    Lay a = L(); sgn = 1;
    double W2 = p("lightW") / 2, L2 = p("lightL") / 2;
    if (side) {
      double half = L2 + a.ys;
      PY(new double[][] { new double[] { W2 + a.tipX, a.zRearOut }, new double[] { W2 + a.webOutX, a.zRearOut }, new double[] { W2 + a.webOutX, a.zFront }, new double[] { W2 + a.tipX, a.zFront },
        new double[] { W2 + a.tipX, a.zf }, new double[] { W2 + a.webInX, a.zf }, new double[] { W2 + a.webInX, a.zRearIn }, new double[] { W2 + a.tipX, a.zRearIn } }, -half, half, false, "side channel");
      log.AppendLine(String.Format("  side channel length {0:F1}", 2 * half));
    } else {
      double half = W2 + a.xe;
      PX(new double[][] { new double[] { L2 + a.tipY, a.zRearOut }, new double[] { L2 + a.webOutY, a.zRearOut }, new double[] { L2 + a.webOutY, a.zFront }, new double[] { L2 + a.tipY, a.zFront },
        new double[] { L2 + a.tipY, a.zf }, new double[] { L2 + a.webInY, a.zf }, new double[] { L2 + a.webInY, a.zRearIn }, new double[] { L2 + a.tipY, a.zRearIn } }, -half, half, false, "end channel");
      log.AppendLine(String.Format("  end channel length {0:F1}", 2 * half));
    }
    Finish(path, side ? "lb_channel_side" : "lb_channel_end", 0.74, 0.75, 0.77, imgDir, "*Isometric", 7);
  }
  static MathTransform Xf(double[] rot, double tx, double ty, double tz) {
    MathUtility mu = (MathUtility)sw.GetMathUtility();
    return (MathTransform)mu.CreateTransform(new double[] { rot[0], rot[1], rot[2], rot[3], rot[4], rot[5], rot[6], rot[7], rot[8], tx * MM, ty * MM, tz * MM, 1, 0, 0, 0 });
  }
  static Component2 Place(AssemblyDoc asm, ModelDoc2 adoc, string file, MathTransform t) {
    int e = 0, w = 0;
    if (!System.IO.File.Exists(file)) { log.AppendLine("!! missing " + file); return null; }
    sw.OpenDoc6(file, (int)swDocumentTypes_e.swDocPART, (int)swOpenDocOptions_e.swOpenDocOptions_Silent, "", ref e, ref w);
    sw.ActivateDoc3(adoc.GetTitle(), false, (int)swRebuildOnActivation_e.swDontRebuildActiveDoc, ref e);
    Component2 cmp = (Component2)asm.AddComponent5(file, (int)swAddComponentConfigOptions_e.swAddComponentConfigOptions_CurrentSelectedConfig, "", false, "", 0, 0, 0);
    if (cmp == null) { log.AppendLine("!! could not add " + file); return null; }
    adoc.ClearSelection2(true); cmp.Select4(false, null, false); asm.UnfixComponent();
    cmp.Transform2 = t;
    adoc.ClearSelection2(true); cmp.Select4(false, null, false); asm.FixComponent();
    double[] b = (double[])cmp.GetBox(false, false);
    log.AppendLine(String.Format("  {0,-26} x {1,7:F1}..{4,7:F1}  y {2,7:F1}..{5,7:F1}  z {3,7:F1}..{6,7:F1}", System.IO.Path.GetFileNameWithoutExtension(file), b[0] * 1000, b[1] * 1000, b[2] * 1000, b[3] * 1000, b[4] * 1000, b[5] * 1000));
    return cmp;
  }
  static void BuildAssembly(string dir, string imgDir) {
    int e = 0, w = 0;
    string path = dir + SEP + "lb_light_box.SLDASM";
    double[] I = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }, R = { -1, 0, 0, 0, -1, 0, 0, 0, 1 };   // R: half a turn about Z
    double W2 = p("lightW") / 2, L2 = p("lightL") / 2;
    ModelDoc2 adoc;
    if (System.IO.File.Exists(path)) {
      adoc = (ModelDoc2)sw.OpenDoc6(path, (int)swDocumentTypes_e.swDocASSEMBLY, (int)swOpenDocOptions_e.swOpenDocOptions_Silent, "", ref e, ref w);
      if (adoc == null) { log.AppendLine("!! could not open the assembly, err " + e); return; }
      adoc = (ModelDoc2)sw.ActivateDoc3(adoc.GetTitle(), false, (int)swRebuildOnActivation_e.swRebuildActiveDoc, ref e);
      adoc.ForceRebuild3(false);
      log.AppendLine("assembly: already exists; reopened and rebuilt (component positions are as first placed)");
    } else {
      string tpl = sw.GetUserPreferenceStringValue((int)swUserPreferenceStringValue_e.swDefaultTemplateAssembly);
      adoc = (ModelDoc2)sw.NewDocument(tpl, 0, 0, 0);
      if (adoc == null) { log.AppendLine("!! could not start an assembly"); return; }
      AssemblyDoc asm = (AssemblyDoc)adoc;
      Place(asm, adoc, dir + SEP + "lb_housing.SLDPRT", Xf(I, 0, 0, 0));
      Place(asm, adoc, dir + SEP + "lb_diffuser.SLDPRT", Xf(I, 0, 0, 0));
      Place(asm, adoc, dir + SEP + "lb_channel_side.SLDPRT", Xf(I, 0, 0, 0));
      Place(asm, adoc, dir + SEP + "lb_channel_side.SLDPRT", Xf(R, 0, 0, 0));
      Place(asm, adoc, dir + SEP + "lb_channel_end.SLDPRT", Xf(I, 0, 0, 0));
      Place(asm, adoc, dir + SEP + "lb_channel_end.SLDPRT", Xf(R, 0, 0, 0));
      // corners: hand A as built at (+X, +Y); the diagonal corner is the same part turned half round; hand B for the other two
      Place(asm, adoc, dir + SEP + "lb_corner_block_A.SLDPRT", Xf(I, W2, L2, 0));
      Place(asm, adoc, dir + SEP + "lb_corner_block_A.SLDPRT", Xf(R, -W2, -L2, 0));
      Place(asm, adoc, dir + SEP + "lb_corner_block_B.SLDPRT", Xf(I, -W2, L2, 0));
      Place(asm, adoc, dir + SEP + "lb_corner_block_B.SLDPRT", Xf(R, W2, -L2, 0));
      Place(asm, adoc, dir + SEP + "lb_bracket_A.SLDPRT", Xf(I, W2, L2, 0));      // top corners: plain brackets
      Place(asm, adoc, dir + SEP + "lb_bracket_B.SLDPRT", Xf(I, -W2, L2, 0));
      Place(asm, adoc, dir + SEP + "lb_foot_A.SLDPRT", Xf(R, -W2, -L2, 0));       // bottom corners: feet
      Place(asm, adoc, dir + SEP + "lb_foot_B.SLDPRT", Xf(R, W2, -L2, 0));
      adoc.ClearSelection2(true);
      adoc.EditRebuild3();
      bool ok = adoc.Extension.SaveAs(path, 0, (int)swSaveAsOptions_e.swSaveAsOptions_Silent, null, ref e, ref w);
      log.AppendLine("assembly: saved " + ok + (e != 0 ? " err " + e : ""));
    }
    // spacers in the assembly: added to an existing file too, if it has none. They sit inside the channel slots behind
    // the diffuser, so they only show with a channel hidden or in a section view.
    {
      AssemblyDoc asm2 = (AssemblyDoc)adoc; Lay a = L();
      int have = 0; object[] comps = (object[])asm2.GetComponents(true);
      if (comps != null) foreach (object o in comps) if (((Component2)o).Name2.StartsWith("lb_spacer")) have++;
      if (have == 0) {
        string sp = dir + SEP + "lb_spacer.SLDPRT";
        double len = p("spacerLen"), xw = W2 + a.webInX - 0.1, yw = L2 + a.webInY - 0.1;
        int ns = (int)p("spacerPerSide"), ne = (int)p("spacerPerEnd");
        double freeS = 2 * (L2 + a.ys - p("tongueLen")), gapS = (freeS - ns * len) / (ns + 1), freeE = 2 * (W2 + a.xe - p("tongueLen")), gapE = (freeE - ne * len) / (ne + 1);
        for (int i = 0; i < ns; i++) {
          double y0 = -freeS / 2 + gapS + i * (len + gapS);           // start of this spacer along the side channel
          Place(asm2, adoc, sp, Xf(new double[] { 0, 1, 0, -1, 0, 0, 0, 0, 1 }, xw, y0, a.zb));          // +X side: spacer x up the channel, its y into the slot
          Place(asm2, adoc, sp, Xf(new double[] { 0, -1, 0, 1, 0, 0, 0, 0, 1 }, -xw, -y0, a.zb));        // -X side
        }
        for (int i = 0; i < ne; i++) {
          double x0 = -freeE / 2 + gapE + i * (len + gapE);
          Place(asm2, adoc, sp, Xf(new double[] { -1, 0, 0, 0, -1, 0, 0, 0, 1 }, -x0, yw, a.zb));        // +Y end
          Place(asm2, adoc, sp, Xf(new double[] { 1, 0, 0, 0, 1, 0, 0, 0, 1 }, x0, -yw, a.zb));          // -Y end
        }
        adoc.ClearSelection2(true); adoc.EditRebuild3();
        log.AppendLine("assembly: " + (2 * ns + 2 * ne) + " spacers added");
      } else log.AppendLine("assembly: " + have + " spacers already in it");
    }
    {
      AssemblyDoc asm3 = (AssemblyDoc)adoc; int have = 0; object[] comps = (object[])asm3.GetComponents(true);
      // The two-cheek handle of Nov 23 (lb_handle_A, _B, _bar) is superseded: take it out if it is there.
      int gone = 0;
      if (comps != null) foreach (object o in comps) {
        Component2 c = (Component2)o; string nm = c.Name2;
        if (nm.StartsWith("lb_handle")) { adoc.ClearSelection2(true); c.Select4(false, null, false); if (adoc.Extension.DeleteSelection2(0)) gone++; else log.AppendLine("  !! could not remove " + nm); }
        if (nm.StartsWith("lb_saddle_handle")) have++;
      }
      if (gone > 0) log.AppendLine("assembly: old two-cheek handle removed (" + gone + " components)");
      // Saddle handle: its x runs along the channel (global Y), its y across (global X), its z away from the lamp (global -Z);
      // its origin is on top of the lid, midway between the four inserts.
      if (have == 0) {
        Place(asm3, adoc, dir + SEP + "lb_saddle_handle.SLDPRT", Xf(new double[] { 0, 1, 0, 1, 0, 0, 0, 0, -1 }, 0, p("sdHandleY"), -p("lightH")));
        log.AppendLine("assembly: saddle handle added, " + p("sdHandleY").ToString("F0") + " from the middle of the length (ASSUMED; the insert position along the lamp has not been measured)");
      } else log.AppendLine("assembly: saddle handle already in it");
      adoc.ClearSelection2(true); adoc.EditRebuild3();
    }
    if (imgDir != "") {
      try { ((ModelView)adoc.ActiveView).FrameState = (int)swWindowState_e.swWindowMaximized; } catch (Exception) { }   // a reopened assembly comes up in a small window
      foreach (string[] v in new string[][] { new string[] { "*Isometric", "7", "assem_iso.jpg" }, new string[] { "*Front", "1", "assem_front.jpg" }, new string[] { "*Back", "2", "assem_back.jpg" },
          new string[] { "*Right", "4", "assem_side.jpg" }, new string[] { "*Bottom", "6", "assem_bottom.jpg" } }) {
        adoc.ShowNamedView2(v[0], int.Parse(v[1])); adoc.ViewZoomtofit2(); adoc.GraphicsRedraw2();
        adoc.Extension.SaveAs(imgDir + SEP + v[2], 0, (int)swSaveAsOptions_e.swSaveAsOptions_Silent | (int)swSaveAsOptions_e.swSaveAsOptions_Copy, null, ref e, ref w);
      }
      // close-ups of a top corner and a bottom corner (model metres: two opposite corners of the box to fill the window)
      double W2m = p("lightW") / 2 * MM, L2m = p("lightL") / 2 * MM;
      foreach (string[] v in new string[][] { new string[] { "*Front", "1", "corner_top_front.jpg", "1" }, new string[] { "*Back", "2", "corner_top_back.jpg", "1" },
          new string[] { "*Front", "1", "corner_bottom_front.jpg", "-1" } }) {
        double sy = double.Parse(v[3]);
        adoc.ShowNamedView2(v[0], int.Parse(v[1]));
        adoc.ViewZoomTo2(W2m - 0.085, sy * (L2m - 0.085), -0.06, W2m + 0.03, sy * (L2m + 0.03), 0.05);
        adoc.GraphicsRedraw2();
        adoc.Extension.SaveAs(imgDir + SEP + v[2], 0, (int)swSaveAsOptions_e.swSaveAsOptions_Silent | (int)swSaveAsOptions_e.swSaveAsOptions_Copy, null, ref e, ref w);
      }
      adoc.ShowNamedView2("*Isometric", 7); adoc.ViewZoomtofit2();
    }
    adoc.Save3((int)swSaveAsOptions_e.swSaveAsOptions_Silent, ref e, ref w);
  }

  // ---------------------------------------------------------------- carry handle: two cheeks and a round bar across the top
  // A cheek is a flat plate on the outside of a TOP bracket's leg, held by the same two M3 screws (longer) that hold the
  // leg to the corner cap. A lip hooks under the bottom of the leg, so the lift goes cheek -> leg -> pad -> M6 insert in
  // the housing; the screws only hold the cheek on. A stem runs up past the top end to a boss with a blind socket.
  // The bar (dowel or tube, gripD) sits in the two sockets and is trapped between the cheeks: no fastener on it.
  // Corner-local frame of a top corner (+y is up, past the top end). Prints outside face down: no supports.
  static void BuildHandle(string path, string imgDir, string tag) {
    if (!OpenOrNew(path)) return;
    Lay a = L();
    double t = p("brkT"), bw = p("brkW"), y1 = a.yi - bw / 2, y2 = a.yi + bw / 2, xo = a.jog + t;
    double ct = p("cheekT"), yBar = p("handleUp"), zBar = p("handleZ"), gd = p("gripD"), rb = gd / 2 + p("bossWall"), bl = p("bossLen");
    double zA = a.zLeg - bw, zB = a.zLeg, yL = y1 - p("lipH") - 0.3, sp = p("brkScrewSpan") / 2;
    PX(new double[][] { new double[] { yL, zA }, new double[] { yL, zB }, new double[] { y2 + 10, zB }, new double[] { yBar, zBar + rb }, new double[] { yBar, zBar - rb }, new double[] { y2 - 6, zA } },
      xo, xo + ct, false, "cheek");
    CX(new double[][] { new double[] { yBar, zBar, 2 * rb } }, xo - bl, xo + ct, false, "boss");
    PX(Rect(yL, zA, y1 - 0.3, zB), xo - p("lipDeep"), xo + 0.5, false, "lip under the leg");
    CX(new double[][] { new double[] { yBar, zBar, gd + p("gripClr") } }, xo - bl - 1, xo + ct - p("socketFloor"), true, "socket");
    CX(new double[][] { new double[] { a.yi - sp, a.zScrew, p("screwClrD") }, new double[] { a.yi + sp, a.zScrew, p("screwClrD") } }, xo - 1, xo + ct + 1, true, "screw holes");
    Fil(4, "cheek corners", V(xo + ct / 2, yL, zA), V(xo + ct / 2, yL, zB));
    Fil(12, "stem blend", V(xo + ct / 2, y2 + 10, zB), V(xo + ct / 2, y2 - 6, zA));
    Fil(p("insideR"), "boss root", V(xo, yBar - rb, zBar));
    Cham(p("bedChamSmall"), "bed face chamfer", V(xo + ct, a.yi, a.zScrew + 5));
    double barLen = p("lightW") + 2 * (xo + ct - p("socketFloor")) - 2 * p("barEndClr"), depth = bl + ct - p("socketFloor");
    double F = p("lampWeightN") / 2, arm = Math.Max(0, zA - zBar), S = F * arm / Math.Max(1, a.zScrew - zA);
    log.AppendLine(String.Format("  handle: bar {0:F1} dia, CUT {1:F0} mm ({2:F2} in); sockets {3:F1} deep; bar centre {4:F0} above the top end, {5:F0} behind the front of the housing", gd, barLen, barLen / 25.4, depth, yBar, -zBar));
    log.AppendLine(String.Format("  handle: {0:F0} mm of finger room between the bar and the top of the corner caps; boss {1:F1} dia", yBar - gd / 2 - a.bumpY, 2 * rb));
    log.AppendLine(String.Format("  handle: {0:F1} N per cheek at rest; lip takes it under the leg; bar is {1:F0} behind the lip, so the two M3 see {2:F0} N of shear between them ({3:F0} N at 3 g)", F, arm, S, 3 * S));
    log.AppendLine(String.Format("  handle: screws are M3 x {0:F0} here ({1:F0} cheek + {2:F0} leg + 5 in the insert); lamp hangs {3:F1} deg off plumb from the bar", Math.Ceiling((ct + t + 5) / 2) * 2, ct, t,
      Math.Atan2(Math.Abs(zBar + 33), p("lightL") / 2 + yBar) * 180 / Math.PI));
    if (yBar - gd / 2 - a.bumpY < 28) log.AppendLine("  !! under 28 mm of finger room under the bar");
    if (xo - p("lipDeep") < a.bumpX + 0.5) log.AppendLine("  !! lip reaches the corner cap");
    Finish(path, tag, 0.15, 0.2, 0.35, imgDir, "*Isometric", 7);
  }
  static void BuildBar(string path, string imgDir) {
    if (!OpenOrNew(path)) return;
    Lay a = L(); sgn = 1;
    double xo = a.jog + p("brkT"), half = p("lightW") / 2 + xo + p("cheekT") - p("socketFloor") - p("barEndClr");
    CX(new double[][] { new double[] { p("lightL") / 2 + p("handleUp"), p("handleZ"), p("gripD") } }, -half, half, false, "bar");   // stand-in, global frame
    Finish(path, "lb_handle_bar", 0.72, 0.6, 0.42, imgDir, "*Isometric", 7);
  }

  // ---------------------------------------------------------------- saddle handle on the back of the driver channel (Nov 24)
  // One printed piece. A saddle sits on the channel lid, over the hanger plate and its hardware, with a leg down each
  // side to the two M6 inserts there (four screws). A bail of round bar stands on the saddle; the hand goes through
  // across the channel. Replaces the two-cheek handle concept above.
  // Own frame: x along the channel (0 midway between the inserts), y across it (0 on the centre line), z = 0 on the
  // top of the lid, +z away from the lamp. Prints as modelled, legs on the bed.
  // The legs do NOT step in under the lid to reach the inserts. Printed this way up a leg bends across its layers,
  // so nothing asks it to flex: the legs clear the lid by sdLidClr and a washer on each insert takes up the gap.
  class Sd { public double hl, yi, yo, yr, zr, zt, r, R, xl, xa, zc, xe, zBot, zLip, zi, xs, hf, hw; }
  static Sd SdL() {
    Sd s = new Sd();
    s.hl = p("sdLidW") / 2; s.yi = s.hl + p("sdLidClr"); s.yo = s.yi + p("sdLegT");
    s.yr = s.hl - p("sdJunkIn") + p("sdJunkSide"); s.zr = p("sdRecessH"); s.zt = s.zr + p("sdRoofT");
    s.r = p("sdGripD") / 2; s.R = p("sdBendR"); s.xl = p("sdOpenL") / 2 + s.r; s.xa = s.xl - s.R; s.zc = s.zt + p("sdOpenH") + s.r;
    s.xe = s.xl + s.r + p("sdBaseR") + p("sdEndMargin");
    s.zi = -p("sdInsDown"); s.zBot = s.zi - p("sdLegBelow"); s.zLip = -p("sdLipH"); s.xs = p("sdInsSpan") / 2;
    s.hf = s.hl - p("sdInsRecess"); s.hw = s.hl - p("sdLidStep");
    return s;
  }
  // cylinders along y: each entry {x, z, dia}
  static Feature CY(double[][] xzd, double y1, double y2, bool cut, string name) {
    double ym = (y1 + y2) / 2;
    Open(PlaneAt(1, ym));
    foreach (double[] c in xzd) Circle(V(c[0], ym, c[1]), c[2]);
    Feature f = ExtrudeMid(Close(name + " sketch"), y2 - y1, cut);
    Name(f, name);
    return f;
  }
  // slot cut along y: w wide (x), centre (x0, z0), the centre can move fl each way in z
  static Feature SlotY(double x0, double z0, double w, double fl, double y1, double y2, string name) {
    double ym = (y1 + y2) / 2, r = w / 2;
    Open(PlaneAt(1, ym));
    Ln(V(x0 - r, ym, z0 - fl), V(x0 - r, ym, z0 + fl));
    CircArcM(V(x0, ym, z0 + fl), V(x0 - r, ym, z0 + fl), V(x0, ym, z0 + fl + r), V(x0 + r, ym, z0 + fl));
    Ln(V(x0 + r, ym, z0 + fl), V(x0 + r, ym, z0 - fl));
    CircArcM(V(x0, ym, z0 - fl), V(x0 + r, ym, z0 - fl), V(x0, ym, z0 - fl - r), V(x0 - r, ym, z0 - fl));
    Feature f = ExtrudeMid(Close(name + " sketch"), y2 - y1, true);
    Name(f, name);
    return f;
  }
  static double FaceDist(double[] q) {
    object[] bodies = (object[])((PartDoc)doc).GetBodies2((int)swBodyType_e.swSolidBody, true);
    double best = 1e9;
    if (bodies != null) foreach (Body2 bd in bodies) {
      object[] fs = (object[])bd.GetFaces(); if (fs == null) continue;
      foreach (object o in fs) {
        double[] c = (double[])((Face2)o).GetClosestPointOn(q[0] * MM, q[1] * MM, q[2] * MM); if (c == null) continue;
        double dd = Math.Sqrt((c[0] - q[0] * MM) * (c[0] - q[0] * MM) + (c[1] - q[1] * MM) * (c[1] - q[1] * MM) + (c[2] - q[2] * MM) * (c[2] - q[2] * MM));
        if (dd < best) best = dd;
      }
    }
    return best / MM;
  }
  // quarter of a torus joining the end of the grip bar (at x = xa, centre height zc) to the top of a bail leg.
  // Which way a blind revolve turns is not something to trust: build it, look for the outside of the bend, flip if it is not there.
  static void Elbow(double xa, double zc, double R, double d, int side, string name) {
    double c45 = Math.Sqrt(0.5);
    for (int attempt = 0; attempt < 2; attempt++) {
      Open(PlaneAt(0, xa));
      Circle(V(xa, 0, zc), d);
      double[] a0 = S(V(xa, -30, zc - R)), a1 = S(V(xa, 30, zc - R));
      SketchSegment axis = (SketchSegment)doc.SketchManager.CreateCenterLine(a0[0], a0[1], a0[2], a1[0], a1[1], a1[2]);
      Feature sk = Close(name + " sketch");
      doc.ClearSelection2(true);
      sk.Select2(false, 0);
      SelectData sd = (SelectData)((SelectionMgr)doc.SelectionManager).CreateSelectData();
      sd.Mark = 16;
      if (axis != null) axis.Select4(true, sd);
      Feature f = (Feature)doc.FeatureManager.FeatureRevolve2(true, true, false, false, attempt == 1, false,
        (int)swEndConditions_e.swEndCondBlind, 0, Math.PI / 2, 0, false, false, 0, 0, 0, 0, 0, true, true, true);
      if (f == null) { log.AppendLine("  !! " + name + ": revolve returned nothing (attempt " + attempt + ")"); doc.ClearSelection2(true); sk.Select2(false, 0); doc.Extension.DeleteSelection2(0); continue; }
      double miss = FaceDist(V(xa + side * (R + d / 2) * c45, 0, zc - R + (R + d / 2) * c45));
      if (miss < 0.05) { f.Name = name; return; }
      doc.ClearSelection2(true); f.Select2(false, 0);
      doc.Extension.DeleteSelection2((int)swDeleteSelectionOptions_e.swDelete_Absorbed);
    }
    log.AppendLine("  !! " + name + ": could not turn the elbow the right way");
  }
  static void BuildSaddle(string path, string imgDir) {
    if (!OpenOrNew(path)) return;
    sgn = 1; Sd s = SdL();
    double lc = p("sdLeadCham");
    PX(new double[][] { new double[] { s.yo, s.zBot }, new double[] { s.yo, s.zt }, new double[] { -s.yo, s.zt }, new double[] { -s.yo, s.zBot },
      new double[] { -s.yi - lc, s.zBot }, new double[] { -s.yi, s.zBot + lc }, new double[] { -s.yi, 0 }, new double[] { -s.yr, 0 }, new double[] { -s.yr, s.zr },
      new double[] { s.yr, s.zr }, new double[] { s.yr, 0 }, new double[] { s.yi, 0 }, new double[] { s.yi, s.zBot + lc }, new double[] { s.yi + lc, s.zBot } }, -s.xe, s.xe, false, "saddle");
    // legs: full depth only round the inserts, then up a printable slope to a short lip that runs to the ends
    double Lb = p("sdLegHalf"), run = (s.zLip - s.zBot) / Math.Tan(p("sdSkirtSlope") * Math.PI / 180);
    foreach (int e in new int[] { 1, -1 })
      PY(new double[][] { new double[] { e * Lb, s.zBot - 1 }, new double[] { e * Lb, s.zBot }, new double[] { e * (Lb + run), s.zLip }, new double[] { e * (s.xe + 1), s.zLip }, new double[] { e * (s.xe + 1), s.zBot - 1 } },
        -s.yo - 1, s.yo + 1, true, e > 0 ? "skirt cut +x" : "skirt cut -x");
    // bail: two round legs, a round grip, and a quarter torus at each corner
    Cyls(new double[][] { new double[] { s.xl, 0, 2 * s.r }, new double[] { -s.xl, 0, 2 * s.r } }, s.zt - 1, s.zc - s.R, false, "bail legs");
    CX(new double[][] { new double[] { 0, s.zc, 2 * s.r } }, -s.xa, s.xa, false, "grip bar");
    Elbow(s.xa, s.zc, s.R, 2 * s.r, 1, "elbow +x");
    Elbow(-s.xa, s.zc, s.R, 2 * s.r, -1, "elbow -x");
    SlotY(s.xs, s.zi, p("sdSlotW"), p("sdSlotFloat"), -s.yo - 1, s.yo + 1, "M6 slots +x");
    SlotY(-s.xs, s.zi, p("sdSlotW"), p("sdSlotFloat"), -s.yo - 1, s.yo + 1, "M6 slots -x");
    FilC(p("sdBaseR"), "bail base +x", V(s.xl + s.r, 0, s.zt));
    FilC(p("sdBaseR"), "bail base -x", V(-s.xl - s.r, 0, s.zt));
    Fil(2.0, "recess corners", V(0, s.yr, s.zr), V(0, -s.yr, s.zr));
    Fil(1.0, "land corners", V(0, s.yi, 0), V(0, -s.yi, 0));
    Fil(3.0, "roof corners", V(s.xe, s.yo, 3), V(s.xe, -s.yo, 3), V(-s.xe, s.yo, 3), V(-s.xe, -s.yo, 3));
    FilC(p("sdEdgeR"), "roof top edge", V(0, s.yo, s.zt));
    ChamE(p("bedChamSmall"), "bed chamfer", V(0, s.yo, s.zBot), V(0, -s.yo, s.zBot));

    // ---- what the numbers mean
    double W = p("lampWeightN") + p("frameWeightN"), d = 2 * s.r, wall = 2.6;
    double Zsolid = Math.PI * d * d * d / 32, Zshell = Math.PI * (Math.Pow(d, 4) - Math.Pow(d - 2 * wall, 4)) / 64 / s.r;
    log.AppendLine(String.Format("  saddle: {0:F1} long, {1:F1} wide over the legs, {2:F1} tall as printed; top of the grip {3:F1} above the lid", 2 * s.xe, 2 * s.yo, s.zc + s.r - s.zBot, s.zc + s.r));
    log.AppendLine(String.Format("  hand opening {0:F1} x {1:F1} ({2:F2} x {3:F2} in), top corners R {4:F1}; grip {5:F1} dia, {6:F0} of it straight", p("sdOpenL"), p("sdOpenH"), p("sdOpenL") / 25.4, p("sdOpenH") / 25.4, s.R - s.r, d, 2 * s.xa));
    log.AppendLine(String.Format("  roof: lands {0:F1} wide on the lid each side; recess {1:F1} wide x {2:F1} high over hardware {3:F1} wide x {4:F1} high ({5:F1} clear above, {6:F1} each side), open at both ends",
      s.hl - s.yr, 2 * s.yr, s.zr, 2 * (s.hl - p("sdJunkIn")), p("sdJunkH"), s.zr - p("sdJunkH"), p("sdJunkSide")));
    double gap = p("sdLidClr") + p("sdInsRecess");
    log.AppendLine(String.Format("  legs: {0:F1} thick, inside faces {1:F2} apart: {2:F1} clear of the lid ({3:F2}) each side, so it drops straight on. No snap, no step.", p("sdLegT"), 2 * s.yi, p("sdLidClr"), 2 * s.hl));
    log.AppendLine(String.Format("  legs: gap to each insert flange {0:F2}; SPACER WASHER {1:F1} thick on each insert leaves {2:F2}. Each 0.1 left over bends the leg {3:F2} % (across the layers)", gap, p("sdWasherT"), gap - p("sdWasherT"),
      100 * 3 * p("sdLegT") * 0.1 / (2 * p("sdInsDown") * p("sdInsDown"))));
    log.AppendLine(String.Format("  screws: M6 slots {0:F1} wide x {1:F1} tall at x +/-{2:F1}, centre {3:F1} below the lid top (measured Nov 25: 0.594 in to the top edge of the flange + half of 0.486), float {4:F1} up and down; {5:F1} of leg below the slot",
      p("sdSlotW"), p("sdSlotW") + 2 * p("sdSlotFloat"), s.xs, -s.zi, p("sdSlotFloat"), p("sdLegBelow") - p("sdSlotFloat") - p("sdSlotW") / 2));
    log.AppendLine(String.Format("  screws: leg {0:F1} + spacer washer {1:F1} + washer under the head ~1.6 -> M6 x 16 puts {2:F1} into the insert past its flange face", p("sdLegT"), p("sdWasherT"), 16 - p("sdLegT") - p("sdWasherT") - 1.6));
    // carried face down: straight pull on the bail
    double Ls = s.yi + s.yo, cP = d + p("sdBaseR"), be = (s.xe - s.xl) + Ls / 2;
    double mRoof = W / 2 / 4 * (Ls - cP / 2), sRoof = mRoof / (be * p("sdRoofT") * p("sdRoofT") / 6);
    double sBar = W * p("sdOpenL") / 4 / Zshell;
    log.AppendLine(String.Format("  carried face down, {0:F0} N: grip bar {1:F1} MPa (along the strands; shell only, 6 walls); roof between the legs {2:F1} MPa (along the strands); bail legs and saddle legs in plain tension {3:F2} and {4:F2} MPa (across the layers)",
      W, sBar, sRoof, W / 2 / (Math.PI * s.r * s.r), W / 2 / (2 * Lb * p("sdLegT"))));
    // lifted by the handle with the lamp standing: the pull is along the bar
    double hB = s.zc - s.zt, mBase = 0.6 * W * hB / 2, sBase = mBase / Zshell;
    log.AppendLine(String.Format("  lifted with the lamp standing (pull along the bar): bail leg root {0:F1} MPa ACROSS THE LAYERS at rest, {1:F1} at 3 g (shell only; {2:F1} if solid). The R{3:F0} base fillet is there for this.",
      sBase, 3 * sBase, mBase / Zsolid, p("sdBaseR")));
    log.AppendLine(String.Format("  screws at rest: {0:F0} N each if friction is lost; bearing on the slot end {1:F2} MPa", W / 4, W / 4 / (6 * p("sdLegT"))));
    if (s.zr - p("sdJunkH") < 1.0) log.AppendLine("  !! recess is under 1 mm clear of the hardware on the lid");
    if (s.hl - s.yr < 6) log.AppendLine("  !! lands under 6 mm wide");
    if (-s.zBot > p("sdWallDown") - 2) log.AppendLine(String.Format("  !! leg bottom {0:F1} below the lid top, wall taken as {1:F1} tall", -s.zBot, p("sdWallDown")));
    if (p("sdLegBelow") - p("sdSlotFloat") - p("sdSlotW") / 2 < 5) log.AppendLine("  !! under 5 mm of leg below the slot");
    if (-s.zi - p("sdSlotFloat") - p("sdWasherD") / 2 < p("sdSkirtH") + 0.5) log.AppendLine("  !! spacer washer would foul the bottom edge of the lid skirt at the top of the float");
    if (Lb < s.xs + p("sdWasherD") / 2 + 4) log.AppendLine("  !! leg too short for the washers");
    if (s.R <= s.r + 2) log.AppendLine("  !! bend radius too tight for the bar");
    if (Math.Abs(gap - p("sdWasherT")) > 0.15) log.AppendLine("  !! spacer washer does not fill the gap to 0.15");
    saddleViews = true;
    Finish(path, "lb_saddle_handle", 0.15, 0.2, 0.35, imgDir, "*Isometric", 7);
    saddleViews = false;
  }
  // stand-in for the middle of the driver channel: lid, wall, the four insert flanges with a spacer washer on each,
  // and one block for the hanger plate and its hardware. For the clash check only.
  static void BuildChanMock(string path, string imgDir) {
    if (!OpenOrNew(path)) return;
    sgn = 1; Sd s = SdL();
    double ext = 130, fd = p("insFlangeD"), wt = p("sdWasherT"), wod = p("sdWasherD"), jy = s.hl - p("sdJunkIn"), jx = p("sdJunkLen") / 2;
    PX(Rect(-s.hl, -p("sdSkirtH"), s.hl, 0), -ext, ext, false, "lid");
    PX(Rect(-s.hw, -p("sdWallDown"), s.hw, -p("sdSkirtH")), -ext, ext, false, "channel wall");
    PZ(Rect(-jx, -jy, jx, jy), 0, p("sdJunkH"), false, "hanger plate and hardware");
    double[][] at = new double[][] { new double[] { s.xs, s.zi, fd }, new double[] { -s.xs, s.zi, fd } };
    double[][] atW = new double[][] { new double[] { s.xs, s.zi, wod }, new double[] { -s.xs, s.zi, wod } };
    CY(at, s.hw - 1, s.hf, false, "insert flanges +y");
    CY(at, -s.hf, -s.hw + 1, false, "insert flanges -y");
    CY(atW, s.hf, s.hf + wt, false, "spacer washers +y");
    CY(atW, -s.hf - wt, -s.hf, false, "spacer washers -y");
    log.AppendLine(String.Format("  channel mock: lid {0:F2} wide, skirt {1:F1} (est.), wall {2:F2} wide, flange faces {3:F2} apart, washers out to {4:F2}", 2 * s.hl, p("sdSkirtH"), 2 * s.hw, 2 * s.hf, 2 * (s.hf + wt)));
    Finish(path, "lb_mock_channel", 0.75, 0.75, 0.75, imgDir, "*Isometric", 7);
  }

  // ---------------------------------------------------------------- fit gauge
  // A stepped bar to try in the channel slot, and four notches to try on the diffuser edge.
  // Steps get narrower away from the handle. Notches: the pair on the +y edge (the edge with the
  // small mark hole) are slot0 and slot0+d, mark end first; the pair on the -y edge continue.
  static void BuildGauge(string path, string imgDir) {
    if (!OpenOrNew(path)) return;
    double h = p("gaugeH"), sl = p("gaugeStepLen"), w0 = p("gaugeStepW0"), dw = p("gaugeStepDW"), hl = p("gaugeHandleLen"), hw = p("gaugeHandleW");
    int n = (int)p("gaugeSteps");
    List<double[]> up = new List<double[]>(), dn = new List<double[]>();
    up.Add(new double[] { -hl, hw / 2 }); up.Add(new double[] { 0, hw / 2 });
    dn.Add(new double[] { -hl, -hw / 2 }); dn.Add(new double[] { 0, -hw / 2 });
    for (int i = 0; i < n; i++) {
      double w = w0 - i * dw;
      up.Add(new double[] { i * sl, w / 2 }); up.Add(new double[] { (i + 1) * sl, w / 2 });
      dn.Add(new double[] { i * sl, -w / 2 }); dn.Add(new double[] { (i + 1) * sl, -w / 2 });
      log.AppendLine(String.Format("  step {0}: x {1:F0}..{2:F0}  width {3:F2}", i + 1, i * sl, (i + 1) * sl, w));
    }
    dn.Reverse(); up.AddRange(dn);
    Prism(up.ToArray(), 0, h, false, "gauge body");
    double s0 = p("gaugeSlot0"), sd = p("gaugeSlotD"), dep = p("gaugeSlotDepth");
    double[] xs = { -hl * 0.72, -hl * 0.28 };
    for (int k = 0; k < 4; k++) {
      double sw_ = s0 + k * sd, xc = xs[k % 2]; int side = k < 2 ? 1 : -1;
      double ya = side * (hw / 2 - dep), yb = side * (hw / 2 + 1);
      Prism(Rect(xc - sw_ / 2, Math.Min(ya, yb), xc + sw_ / 2, Math.Max(ya, yb)), -1, h + 1, true, "notch " + sw_.ToString("F1"));
      log.AppendLine(String.Format("  notch {0:F1}: x {1:F1}, {2} edge", sw_, xc, side > 0 ? "+y (marked)" : "-y"));
    }
    if (hw - 2 * dep < 6) log.AppendLine("  !! handle web between notches is under 6 mm");
    Cyls(new double[][] { new double[] { -hl + 3.0, hw / 2 - 3.0, 2.0 } }, -1, h + 1, true, "mark hole");
    Finish(path, "lb_fit_gauge", 0.15, 0.2, 0.35, imgDir, "*Isometric", 7);
  }

  static void ExportPrint(string dir, string tag, string[] parts) {
    int e = 0, w = 0;
    int oldQ = sw.GetUserPreferenceIntegerValue((int)swUserPreferenceIntegerValue_e.swSTLQuality);
    bool oldT = sw.GetUserPreferenceToggle((int)swUserPreferenceToggle_e.swSTLDontTranslateToPositive);
    sw.SetUserPreferenceIntegerValue((int)swUserPreferenceIntegerValue_e.swSTLQuality, (int)swSTLQuality_e.swSTLQuality_Fine);
    sw.SetUserPreferenceToggle((int)swUserPreferenceToggle_e.swSTLDontTranslateToPositive, true);
    foreach (string n in parts) {
      ModelDoc2 d = (ModelDoc2)sw.OpenDoc6(dir + "\\lb_" + n + ".SLDPRT", (int)swDocumentTypes_e.swDocPART, (int)swOpenDocOptions_e.swOpenDocOptions_Silent, "", ref e, ref w);
      if (d == null) { log.AppendLine("!! could not open " + n); continue; }
      d = (ModelDoc2)sw.ActivateDoc3(d.GetTitle(), false, (int)swRebuildOnActivation_e.swDontRebuildActiveDoc, ref e);
      string stl = dir + "\\stl\\lb_" + n + "_" + tag + ".STL";
      bool ok = d.Extension.SaveAs(stl, 0, (int)swSaveAsOptions_e.swSaveAsOptions_Silent | (int)swSaveAsOptions_e.swSaveAsOptions_Copy, null, ref e, ref w);
      log.AppendLine(n + ": STL " + ok + "  " + stl);
    }
    sw.SetUserPreferenceIntegerValue((int)swUserPreferenceIntegerValue_e.swSTLQuality, oldQ);
    sw.SetUserPreferenceToggle((int)swUserPreferenceToggle_e.swSTLDontTranslateToPositive, oldT);
  }

  public static string Run(string dir, string what, string imgDir, string stlTag, string stlParts, string[] keys, double[] vals) {
    P = new Dictionary<string, double>(); PKeys = new List<string>(keys);
    for (int i = 0; i < keys.Length; i++) P[keys[i]] = vals[i];
    try { sw = (SldWorks)Marshal.GetActiveObject("SldWorks.Application"); }
    catch (Exception) { return "SolidWorks is not running. Start it and run again."; }
    try {
      if (what == "gauge") BuildGauge(dir + SEP + "lb_fit_gauge.SLDPRT", imgDir);
      if (what == "blockA") { sgn = 1; BuildBlock(dir + SEP + "lb_corner_block_A.SLDPRT", imgDir, "lb_corner_block_A"); }
      if (what == "blockB") { sgn = -1; BuildBlock(dir + SEP + "lb_corner_block_B.SLDPRT", imgDir, "lb_corner_block_B"); }
      if (what == "bracketA") { sgn = 1; BuildBracket(dir + SEP + "lb_bracket_A.SLDPRT", imgDir, "lb_bracket_A"); }
      if (what == "bracketB") { sgn = -1; BuildBracket(dir + SEP + "lb_bracket_B.SLDPRT", imgDir, "lb_bracket_B"); }
      if (what == "footA") { sgn = 1; footMode = true; BuildBracket(dir + SEP + "lb_foot_A.SLDPRT", imgDir, "lb_foot_A"); }
      if (what == "footB") { sgn = -1; footMode = true; BuildBracket(dir + SEP + "lb_foot_B.SLDPRT", imgDir, "lb_foot_B"); }
      if (what == "spacer") BuildSpacer(dir + SEP + "lb_spacer.SLDPRT", imgDir);
      if (what == "housing") BuildHousing(dir + SEP + "lb_housing.SLDPRT", imgDir);
      if (what == "diffuser") BuildDiffuser(dir + SEP + "lb_diffuser.SLDPRT", imgDir);
      if (what == "chanSide") BuildChannel(dir + SEP + "lb_channel_side.SLDPRT", imgDir, true);
      if (what == "chanEnd") BuildChannel(dir + SEP + "lb_channel_end.SLDPRT", imgDir, false);
      if (what == "assembly") BuildAssembly(dir, imgDir);
      if (what == "handleA") { sgn = 1; BuildHandle(dir + SEP + "lb_handle_A.SLDPRT", imgDir, "lb_handle_A"); }
      if (what == "handleB") { sgn = -1; BuildHandle(dir + SEP + "lb_handle_B.SLDPRT", imgDir, "lb_handle_B"); }
      if (what == "bar") BuildBar(dir + SEP + "lb_handle_bar.SLDPRT", imgDir);
      if (what == "saddle") BuildSaddle(dir + SEP + "lb_saddle_handle.SLDPRT", imgDir);
      if (what == "chanMock") BuildChanMock(dir + SEP + "lb_mock_channel.SLDPRT", imgDir);
      if (what == "mock") BuildMock(dir + SEP + "lb_mock_corner.SLDPRT", imgDir);
      if (what == "stl") ExportPrint(dir, stlTag, stlParts.Split(','));
    } catch (Exception ex) { log.AppendLine("!! stopped: " + ex.Message + "\n" + ex.StackTrace); }
    return log.ToString();
  }
}
'@

$params = Get-Content (Join-Path $here "lightbox_params.json") -Raw | ConvertFrom-Json
$keys = @(); $vals = @()
foreach ($prop in $params.PSObject.Properties) { $keys += $prop.Name; $vals += [double]$prop.Value }
Add-Type -TypeDefinition $code -ReferencedAssemblies $refs
foreach ($r in $refs) { [Reflection.Assembly]::LoadFrom($r) | Out-Null }
[Gen]::Run($outDir, $What, $ImgDir, $StlTag, $StlParts, [string[]]$keys, [double[]]$vals)
