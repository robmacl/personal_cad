# Generates the light box v2 printed parts in a running SolidWorks session.
#
#   powershell -ExecutionPolicy Bypass -File lightbox_generate.ps1 [-What gauge|blockA|blockB|bracketA|bracketB|footA|footB|spacer|mock|housing|diffuser|chanSide|chanEnd|assembly] [-ImgDir <dir>]
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
    public double zf, zFront, zRearIn, zRearOut, zb, zSeat, zTop, zScrew;
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
    a.zScrew = (a.zb + a.zSeat) / 2;
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
    a.jog = a.webOutX;
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
    if (!OpenOrNew(path)) return;
    Lay a = L(); LayoutReport(a);
    double lt = p("tongueLen"), tx = a.webInX - p("tongueClrX"), ty = a.webInY - p("tongueClrX");
    // body and tongues, zb..zSeat
    PZ(new double[][] {
      new double[] { a.bumpX, a.bumpY },
      new double[] { a.xe, a.bumpY }, new double[] { a.xe, ty }, new double[] { a.xe - lt, ty }, new double[] { a.xe - lt, a.tipY },
      new double[] { a.tipX, a.tipY },
      new double[] { a.tipX, a.ys - lt }, new double[] { tx, a.ys - lt }, new double[] { tx, a.ys }, new double[] { a.bumpX, a.ys } },
      a.zb, a.zSeat, false, "body and tongues");
    // rim round the diffuser corner, zb..zTop
    PZ(new double[][] {
      new double[] { a.bumpX, a.bumpY },
      new double[] { a.xe, a.bumpY }, new double[] { a.xe, a.webInY }, new double[] { a.webInX, a.webInY },
      new double[] { a.webInX, a.ys }, new double[] { a.bumpX, a.ys } },
      a.zb, a.zTop, false, "rim");
    // seat for the bracket on the side face
    double bw = p("brkW"), bc = p("brkSeatClr");
    PZ(Rect(a.webOutX, a.yi - bw / 2 - bc, a.bumpX + 1, a.yi + bw / 2 + bc), a.zb - 1, a.zTop + 1, true, "bracket seat");
    double sp = p("brkScrewSpan") / 2;
    CX(new double[][] { new double[] { a.yi - sp, a.zScrew, p("pilotD") }, new double[] { a.yi + sp, a.zScrew, p("pilotD") } },
      a.webOutX - p("pilotDepth"), a.webOutX + 1, true, "screw pilots");
    if (a.webOutX - p("pilotDepth") < a.tipX + 1.5) log.AppendLine("  !! screw pilot breaks through the inside of the block");
    if (a.yi - bw / 2 - bc < a.ys + 3) log.AppendLine("  !! bracket seat runs off the end of the side arm");
    // The holes take M3 heat-set inserts (McMaster 94180A333 family, 6.4 long, tapered). Modelled undersize; finished with a drill.
    { double fd = p("insHoleFinishD"), wall = Math.Min(a.zScrew - fd / 2 - a.zb, a.zSeat - a.zScrew - fd / 2);
      log.AppendLine(String.Format("  insert holes: modelled {0:F1} dia x {1:F1} deep, finish to {2:F1}; {3:F2} of plastic above and below at that size; {4:F1} between the hole end and the inside of the block",
        p("pilotD"), p("pilotDepth"), fd, wall, a.webOutX - p("pilotDepth") - a.tipX));
      if (wall < 2.3) log.AppendLine("  !! under 2.3 mm of plastic above or below the insert holes");
      if (p("pilotDepth") < p("insLen") + 1.0) log.AppendLine("  !! insert hole under 1 mm deeper than the insert"); }
    // ---- corners. The block prints flat on its back, so every edge along z is vertical in the print and can be round.
    {
      double zm = (a.zb + a.zTop) / 2, zr = (a.zSeat + a.zTop) / 2, zt = (a.zb + a.zSeat) / 2, rc = p("cornerR"), rimX = a.bumpX - a.webInX, rimY = a.bumpY - a.webInY;
      Fil(rc, "bumper corner", V(a.bumpX, a.bumpY, zm));
      Fil(p("rimInR"), "inside corner of the rim", V(a.webInX, a.webInY, zr));
      Fil(Math.Min(2.0, p("proud") - 0.3), "rim ends", V(a.bumpX, a.ys, zm), V(a.xe, a.bumpY, zm));
      Fil(1.5, "tongue lead-in", V(tx, a.ys - lt, zt), V(a.tipX, a.ys - lt, zt), V(a.xe - lt, ty, zt), V(a.xe - lt, a.tipY, zt));
      FilC(p("edgeR"), "rim top edge", V(a.bumpX, a.ys + 3, a.zTop), V(a.xe + 3, a.bumpY, a.zTop));
      Cham(p("bedChamSmall"), "bed face chamfer", V(a.tipX + 3, a.ys - lt / 2, a.zb));
      double diag = Math.Sqrt(rimX * rimX + rimY * rimY) - rc * (Math.Sqrt(2) - 1) + p("rimInR") * (Math.Sqrt(2) - 1);
      log.AppendLine(String.Format("  bumper rim {0:F2} x {1:F2} thick; across the rounded corner {2:F1}; rim stands {3:F1} proud of the channel faces", rimX, rimY, diag, p("proud")));
      if (diag < 3) log.AppendLine("  !! under 3 mm of rim across the bumper corner");
    }
    Finish(path, tag, 0.15, 0.2, 0.35, imgDir, "*Isometric", 7);
  }

  // ---------------------------------------------------------------- bracket: frame corner to the M6 insert on the angled face
  static bool footMode = false;
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
    prof.Add(new double[] { sc, zJ + sc }); prof.Add(new double[] { a.jog, zJ + a.jog }); prof.Add(new double[] { a.jog, a.zTop });
    prof.Add(new double[] { xo, a.zTop }); prof.Add(new double[] { xo, zO2 });
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
      // Prints sole down. The sole is the lowest thing on the lamp: the corner blocks hang footLift above the table.
      double fc = p("footClr"), yTop = p("footEndClr"), yBot = a.bumpY + p("footLift"), yThin = a.bumpY + p("footBlockClr");
      double zRear = -(p("lightH") + p("footBack")), zStep = a.zRearOut - 0.8, zFwd = a.zTop + p("footFwd");
      double xIn = ex - 0.1, zLegTop = zJ + sc;
      // leg and pad carried down to the sole, standing fc off the housing (end-cap laps, screw heads)
      double fs = (fc + 0.3 - fc * a.nX) / a.dX, fz = -sf + fc * a.nZ + fs * a.dZ;
      PY(new double[][] { new double[] { fc + 0.3, fz }, new double[] { fc + 0.3, zLegTop }, new double[] { xo, zLegTop }, new double[] { xo, zO2 },
        new double[] { ex + tp * a.nX, ez + tp * a.nZ }, new double[] { ex + fc * a.nX, ez + fc * a.nZ } }, y2 - 0.5, yTop + 0.5, false, "foot leg");
      PY(Rect(xIn, zRear, xo, zStep), yTop, yBot, false, "sole under the housing");
      PY(Rect(xIn, zStep - 0.5, xo, zFwd), yThin, yBot, false, "sole under the block");
      // toe: in front of the frame nothing sits above the sole, so it is full depth at the root and tapers to the tip
      double zToe = a.zTop + 0.8, tt = p("footToeTip");
      PX(new double[][] { new double[] { yBot, zToe }, new double[] { yTop, zToe }, new double[] { yTop, zToe + 5 }, new double[] { yBot - tt, zFwd }, new double[] { yBot, zFwd } }, xIn, xo, false, "toe");
      // 45 deg gusset under the part of the leg that sits in the block seat, outside the bumper face of the block
      double gx = a.bumpX + 0.4, gz = a.zTop - (yThin - y2);
      PX(new double[][] { new double[] { y2 - 0.5, zLegTop - 0.5 }, new double[] { y2 - 0.5, a.zTop }, new double[] { y2, a.zTop }, new double[] { yThin + 0.5, gz }, new double[] { yThin + 0.5, zLegTop - 0.5 } },
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
      { double wt = xo - bx0, zh = -p("lightWingDepth"), hh = (yBot - yCut) + (y1 < yCut && zh > zC ? (yCut - y1) * (zh - zC) / (zW - 6 - zC) : 0);   // depth of web + sole where the housing ends
        // Balance: the fixture alone balances cgInset in front of the wing back (Robert, on a straightedge). The frame and
        // diffuser pull the centre of gravity of the whole lamp forward. Bumpers sit bumpIn from each end of the sole.
        double bi = p("bumpIn"), wFix = p("lampWeightN") - p("frameWeightN"), zFix = -(p("lightWingDepth") - p("cgInset")), zFrm = (a.zRearOut + a.zFront) / 2;
        double zcg = (wFix * zFix + p("frameWeightN") * zFrm) / p("lampWeightN"), hcg = p("lightL") / 2 + yBot + p("bumpH");
        double zBf = zFwd - bi, zBr = zRear + bi;
        log.AppendLine(String.Format("  balance: fixture at z {0:F0}, frame at z {1:F0} -> whole lamp at z {2:F0}; height of centre {3:F0} above the table (taken at mid-length)", zFix, zFrm, zcg, hcg));
        log.AppendLine(String.Format("  tips BACKWARD at {0:F1} deg ({1:F0} mm of stance behind the centre), FORWARD at {2:F1} deg ({3:F0} mm in front)",
          Math.Atan2(zcg - zBr, hcg) * 180 / Math.PI, zcg - zBr, Math.Atan2(zBf - zcg, hcg) * 180 / Math.PI, zBf - zcg));
        { double v1b = Math.Atan2(zcg + p("lightH"), p("lightL") / 2) * 180 / Math.PI, v1f = Math.Atan2(a.zFront - zcg, p("lightL") / 2) * 180 / Math.PI;
          log.AppendLine(String.Format("  for comparison, standing on the frame front and the back of the driver channel as v1 does: {0:F1} deg backward, {1:F1} deg forward", v1b, v1f)); }
        double span = zBf - zBr, la = zBf - zcg, lb = span - la, W = p("lampWeightN") / 2;
        { double Rf = W * lb / span, toeArm = Math.Max(0, zBf - a.zTop), Zt = (xo - xIn) * Math.Pow(yBot - yTop, 2) / 6;
          log.AppendLine(String.Format("  toe: front bumper carries {0:F0} N, {1:F0} mm in front of the block -> {2:F2} MPa sustained at the root ({3:F1} deep there)", Rf, toeArm, Rf * toeArm / Zt, yBot - yTop)); }
        // Section where the housing ends (the brace is at its shallowest under load there): sole as flange, brace as web.
        double Mb = W * la * lb / span, Mh = W * la / span * (zh - zBr);
        double tf = yBot - yTop, bf = xo - xIn, hw = hh - tf, Af = bf * tf, Aw = wt * hw, yc = (Af * tf / 2 + Aw * (tf + hw / 2)) / (Af + Aw);
        double It = bf * tf * tf * tf / 12 + Af * (yc - tf / 2) * (yc - tf / 2) + wt * hw * hw * hw / 12 + Aw * (tf + hw / 2 - yc) * (tf + hw / 2 - yc);
        double sg = Mh * Math.Max(yc, hh - yc) / It, sg0 = Mb * (tf / 2) / (bf * tf * tf * tf / 12);
        log.AppendLine(String.Format("  foot span between bumpers {0:F0}; {1:F0} N per foot landing {2:F0} from the front one -> {3:F0} N.mm at the load, {4:F0} where the housing ends", span, W, la, Mb, Mh));
        log.AppendLine(String.Format("  foot sustained bending where the housing ends: sole + brace {0:F0} deep -> {1:F2} MPa (sole alone, at the load, would be {2:F1} MPa)", hh, sg, sg0));
        if (sg > 1.0) log.AppendLine("  !! sustained stress over 1 MPa: creep"); }
      log.AppendLine(String.Format("  M6 line of sight: tool axis crosses the brace at z {0:F0}; brace top held {1:F0} below the axis from z {2:F0} back to the tail", zLos, tR, zC));
      // the side screw-head relief carried through to the end
      PX(Rect(y2 - p("relLen"), -p("relZfar"), yTop - 0.2, -p("relZnear")), -1, sc + p("relDepth"), true, "screw head relief to the end");
      double thin = yBot - yThin, thick = yBot - yTop, wS = xo - xIn, tail = -p("lightWingDepth") - zRear;
      log.AppendLine(String.Format("  foot: sole {0:F1} wide, z {1:F1}..{2:F1} ({3:F0} long); {4:F1} thick under the housing, {5:F1} under the block; table plane y = {6:F2}", wS, zRear, zFwd, zFwd - zRear, thick, thin, yBot));
      log.AppendLine(String.Format("  foot: housing end sits {0:F1} above the sole (end screw heads {1:F1}), block rim {2:F1} above it; table to housing end {3:F1}", yTop, p("endHeadH"), p("footBlockClr"), yBot));
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
        Fil(rv, "leg top corner", V(xm, y1, a.zTop));
        Fil(rv, "pad end corner", V(pmx, y1, pmz));
      } else {
        ChamE(rv, "leg top corners", V(xm, y1, a.zTop), V(xm, y2, a.zTop));
        ChamE(rv, "pad end corners", V(pmx, y1, pmz), V(pmx, y2, pmz));
        Fil(p("bendOutR"), "outside of the bend", V(xo, ym, zO2));
      }
      Fil(rv * 0.75, "leg top outer edge", V(xo, ym, a.zTop));
      Fil(rv * 0.75, "pad end outer edge", V(ex + tp * a.nX, ym, ez + tp * a.nZ));
      Fil(re, "leg top inner edge", V(a.jog, ym, a.zTop));
      Fil(re, "pad end inner edge", V(ex, ym, ez));
      if (footMode) {
        double fc = p("footClr"), yTop = p("footEndClr"), yBot = a.bumpY + p("footLift"), yThin = a.bumpY + p("footBlockClr");
        double zRear = -(p("lightH") + p("footBack")), zFwd = a.zTop + p("footFwd"), xIn = ex - 0.1, bx0 = fc + 0.3;
        double fs = (fc + 0.3 - fc * a.nX) / a.dX, fz = -sf + fc * a.nZ + fs * a.dZ, rT = p("footCornerR");
        double s0 = (bx0 - a.cX) / a.nX, zC = a.cZ + s0 * a.nZ + p("toolR") / Math.Abs(a.nX), yCut = a.yi + p("toolR"), zW = zO2 + 1;
        Fil(rT, "sole tail corners", V(xo, (yTop + yBot) / 2, zRear), V(xIn, (yTop + yBot) / 2, zRear));
        Fil(p("footFrontR"), "sole front corners", V(xo, (yThin + yBot) / 2, zFwd), V(xIn, (yThin + yBot) / 2, zFwd));
        Fil(p("braceKinkR"), "brace kink", V((bx0 + xo) / 2, yCut, zC));
        Fil(rv, "brace top corner", V((bx0 + xo) / 2, y1, zW - 6));
        Fil(p("insideR"), "inside corner of the foot leg", V(fc + 0.3, (y2 + yTop) / 2, fz));
        Fil(p("insideR"), "brace to sole", V(bx0, yTop, zC - 20));
        FilC(p("soleTopR"), "sole top edge, tail", V(xIn, yTop, zRear + 40));
        { double zt0 = a.zTop + 5.8, tt = p("footToeTip"); FilC(p("soleTopR"), "toe top edge", V(xIn, (yTop + yBot - tt) / 2, (zt0 + zFwd) / 2)); }
        Cham(p("bedCham"), "bed face chamfer", V(xIn + 15, yBot, zRear + 40));
      } else {
        // bed-face edges, chained along tangents; the small relief arc at the inside of the bend is left as it is
        ChamC(p("bedChamSmall"), "bed face chamfer", V(xo, y1, 0), V(sc, y1, -10), V(a.jog, y1, a.zTop - 6),
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
    double W2 = p("lightW") / 2, L2 = p("lightL") / 2, sf = p("lightSideFlat"), wd = p("lightWingDepth"), run = -p("lightSlopeLen") * a.dX, cw = p("lightChanW") / 2, H = p("lightH");
    PY(new double[][] { new double[] { W2, 0 }, new double[] { W2, -sf }, new double[] { W2 - run, -wd }, new double[] { cw, -wd }, new double[] { cw, -H }, new double[] { -cw, -H },
      new double[] { -cw, -wd }, new double[] { -(W2 - run), -wd }, new double[] { -W2, -sf }, new double[] { -W2, 0 } }, -L2, L2, false, "housing");
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
    if (imgDir != "") {
      try { ((ModelView)adoc.ActiveView).FrameState = (int)swWindowState_e.swWindowMaximized; } catch (Exception) { }   // a reopened assembly comes up in a small window
      foreach (string[] v in new string[][] { new string[] { "*Isometric", "7", "assem_iso.jpg" }, new string[] { "*Front", "1", "assem_front.jpg" }, new string[] { "*Back", "2", "assem_back.jpg" },
          new string[] { "*Right", "4", "assem_side.jpg" }, new string[] { "*Bottom", "6", "assem_bottom.jpg" } }) {
        adoc.ShowNamedView2(v[0], int.Parse(v[1])); adoc.ViewZoomtofit2(); adoc.GraphicsRedraw2();
        adoc.Extension.SaveAs(imgDir + SEP + v[2], 0, (int)swSaveAsOptions_e.swSaveAsOptions_Silent | (int)swSaveAsOptions_e.swSaveAsOptions_Copy, null, ref e, ref w);
      }
      adoc.ShowNamedView2("*Isometric", 7); adoc.ViewZoomtofit2();
    }
    adoc.Save3((int)swSaveAsOptions_e.swSaveAsOptions_Silent, ref e, ref w);
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
